//! T70: keep the `ghoztty` CLI resolvable from any shell — the Windows
//! analog of macOS CommandLineInstaller.swift, which self-heals a
//! ~/.local/bin link + profile PATH entry on every launch. Here the
//! master GUI instance checks on a background thread whether the
//! directory it is running from is on the user PATH
//! (HKCU\Environment\Path) and puts it there when missing, then broadcasts
//! WM_SETTINGCHANGE so shells launched afterwards see it. Idempotent:
//! an entry present in any spelling (case, trailing "\", quotes, or an
//! unexpanded %VAR% form) is detected and left alone.
//!
//! The entry is ONE OWNED value that the last launch re-points (T2169), the
//! way the Mac link follows whichever bundle launched. The directory written
//! is recorded under `HKCU\Software\Ghoztty` (`PathEntry`, `PathEntry-debug`
//! for the debug lineage); the next launch from a different copy drops that
//! recorded entry and writes its own, placed AHEAD of the installed release's
//! entry so `ghoztty` resolves to the copy launched last. The installed
//! release's directory is the MSI's own Environment entry: it is never
//! removed, and a launch from it simply drops the recorded portable entry.
//! Entries nobody recorded (a dir the user added by hand) are left alone.
//!
//! Gates, as on Mac: any real copy heals — the installed release and a
//! portable unpack — but build output and a copy an archive tool extracted
//! into TEMP do not (`install_location.SelfHealGate.not_build_output`), and
//! a Debug build never does (Mac's `#if DEBUG` guard), since it runs beside
//! the user's real install. `GHOZTTY_PATH_SELFHEAL=0`/`off` disables the
//! check entirely; `force` skips both gates (test hook for path-selfheal.ps1,
//! which must exercise the flow with a zig-out debug build).
const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const path_env = @import("../../os/path_env.zig");
const install_location = @import("install_location.zig");

const log = std.log.scoped(.win32_path_installer);

/// Where the owned entry is recorded. Lineage-suffixed like the agent's Run
/// value, so a debug build under `force` never moves the release record.
const owner_key = "Software\\Ghoztty";
const owner_value = if (builtin.mode == .Debug) "PathEntry-debug" else "PathEntry";

/// Run the self-heal on a detached background thread. Registry access is
/// fast, but the WM_SETTINGCHANGE broadcast can block on unresponsive
/// windows, so none of this belongs on the GUI thread during startup.
pub fn ensureOnPathAsync() void {
    const thread = std.Thread.spawn(.{}, run, .{}) catch |err| {
        log.warn("PATH self-heal: thread spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

fn run() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    ensureOnPath(arena_state.allocator()) catch |err| {
        log.warn("PATH self-heal failed: {}", .{err});
    };
}

fn ensureOnPath(arena: std.mem.Allocator) !void {
    const heal_env: ?[]const u8 =
        std.process.getEnvVarOwned(arena, "GHOZTTY_PATH_SELFHEAL") catch null;
    if (heal_env) |v| {
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off")) return;
    }
    const force = if (heal_env) |v| std.ascii.eqlIgnoreCase(v, "force") else false;

    // A Debug build runs next to the user's real install: never touch the
    // CLI setup unless a test opts in (Mac: `checkCommandLineToolOnLaunch`).
    if (builtin.mode == .Debug and !force) return;

    const exe_dir = try std.fs.selfExeDirPathAlloc(arena);

    // Location gate: the entry is owned and re-pointed, so any real copy may
    // write it — the rule is `install_location.SelfHealGate` (T1213, T2169).
    if (!force and !install_location.selfHealAllowed(arena, .not_build_output, exe_dir)) return;

    const install_dir: []const u8 = blk: {
        const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch break :blk "";
        break :blk try std.fs.path.join(arena, &.{ local, install_location.install_subdir });
    };
    const previous = readOwned(arena);

    var key: w32.HKEY = undefined;
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Environment");
    if (w32.RegOpenKeyExW(
        w32.HKEY_CURRENT_USER,
        subkey,
        0,
        w32.KEY_QUERY_VALUE | w32.KEY_SET_VALUE,
        &key,
    ) != w32.ERROR_SUCCESS) return error.RegOpenFailed;
    defer _ = w32.RegCloseKey(key);

    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("Path");

    // Read the current value. A truly clean profile can lack it entirely.
    var vtype: u32 = w32.REG_EXPAND_SZ;
    var raw: []const u8 = "";
    var size: u32 = 0;
    const qrc = w32.RegQueryValueExW(key, value_name, null, &vtype, null, &size);
    if (qrc == w32.ERROR_SUCCESS and size >= 2) {
        const buf = try arena.alloc(u16, (size + 1) / 2);
        var got: u32 = @intCast(buf.len * 2);
        if (w32.RegQueryValueExW(
            key,
            value_name,
            null,
            &vtype,
            @ptrCast(buf.ptr),
            &got,
        ) != w32.ERROR_SUCCESS) return error.RegQueryFailed;
        var wide: []const u16 = buf[0 .. got / 2];
        while (wide.len > 0 and wide[wide.len - 1] == 0) wide = wide[0 .. wide.len - 1];
        raw = try std.unicode.utf16LeToUtf8Alloc(arena, wide);
    } else if (qrc != w32.ERROR_SUCCESS and qrc != w32.ERROR_FILE_NOT_FOUND) {
        return error.RegQueryFailed;
    }

    // Never rewrite a value of a type we don't understand.
    if (vtype != w32.REG_SZ and vtype != w32.REG_EXPAND_SZ) return;

    const new_value = try path_env.repoint(arena, raw, .{
        .dir = exe_dir,
        .previous = previous,
        .install_dir = install_dir,
    }, Expander{ .arena = arena });

    // The record follows the launch even when the PATH already agreed, so a
    // copy that was put there some other way is still the one dropped next.
    // The install's entry is the MSI's, never recorded. Written only once the
    // PATH says the same thing: a record of an entry the PATH never got would
    // forget the one it still has.
    const owned: []const u8 = if (install_dir.len > 0 and path_env.eqlDir(exe_dir, install_dir)) "" else exe_dir;
    const record_changed = !std.mem.eql(u8, previous orelse "", owned);

    const value = new_value orelse {
        if (record_changed) writeOwned(arena, owned);
        return;
    };
    const new_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, value);
    if (w32.RegSetValueExW(
        key,
        value_name,
        0,
        vtype,
        @ptrCast(new_w.ptr),
        @intCast((new_w.len + 1) * 2),
    ) != w32.ERROR_SUCCESS) return error.RegSetFailed;
    if (record_changed) writeOwned(arena, owned);

    log.info("PATH self-heal: user PATH now resolves ghoztty from {s}", .{exe_dir});

    // Nudge Explorer (and anything else listening) so terminals launched
    // from the shell see the new PATH without a sign-out. Timeout-guarded:
    // a hung top-level window must not wedge this thread forever.
    _ = w32.SendMessageTimeoutW(
        w32.HWND_BROADCAST,
        w32.WM_SETTINGCHANGE,
        0,
        @bitCast(@intFromPtr(subkey)),
        w32.SMTO_ABORTIFHUNG,
        1000,
        null,
    );
}

/// `%VAR%` expansion of one PATH entry against this process's environment,
/// for `path_env.repoint`. The entry itself when there is nothing to expand
/// or the expansion fails.
const Expander = struct {
    arena: std.mem.Allocator,

    pub fn expand(self: Expander, entry: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, entry, '%') == null) return entry;
        const entry_w = std.unicode.utf8ToUtf16LeAllocZ(self.arena, entry) catch return entry;
        const need = w32.ExpandEnvironmentStringsW(entry_w, null, 0);
        if (need == 0) return entry;
        const buf = self.arena.alloc(u16, need) catch return entry;
        const written = w32.ExpandEnvironmentStringsW(entry_w, buf.ptr, need);
        if (written == 0 or written > need) return entry;
        return std.unicode.utf16LeToUtf8Alloc(self.arena, buf[0 .. written - 1]) catch entry;
    }
};

/// The entry an earlier launch recorded as owned; null when none is (an
/// absent key or value, or the empty string an install launch leaves).
fn readOwned(arena: std.mem.Allocator) ?[]const u8 {
    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(
        w32.HKEY_CURRENT_USER,
        std.unicode.utf8ToUtf16LeStringLiteral(owner_key),
        0,
        w32.KEY_QUERY_VALUE,
        &key,
    ) != w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(key);

    const name = std.unicode.utf8ToUtf16LeStringLiteral(owner_value);
    var vtype: u32 = 0;
    var size: u32 = 0;
    if (w32.RegQueryValueExW(key, name, null, &vtype, null, &size) != w32.ERROR_SUCCESS) return null;
    if (vtype != w32.REG_SZ or size < 2) return null;
    const buf = arena.alloc(u16, (size + 1) / 2) catch return null;
    var got: u32 = @intCast(buf.len * 2);
    if (w32.RegQueryValueExW(key, name, null, &vtype, @ptrCast(buf.ptr), &got) != w32.ERROR_SUCCESS) return null;
    var wide: []const u16 = buf[0 .. got / 2];
    while (wide.len > 0 and wide[wide.len - 1] == 0) wide = wide[0 .. wide.len - 1];
    const s = std.unicode.utf16LeToUtf8Alloc(arena, wide) catch return null;
    return if (path_env.normalize(s).len == 0) null else s;
}

/// Record `dir` as the owned entry ("" records none). Best effort: a failed
/// write only means the next launch cannot drop this entry, which is the
/// pre-T2169 behavior, so it is logged rather than surfaced.
fn writeOwned(arena: std.mem.Allocator, dir: []const u8) void {
    var key: w32.HKEY = undefined;
    if (w32.RegCreateKeyExW(
        w32.HKEY_CURRENT_USER,
        std.unicode.utf8ToUtf16LeStringLiteral(owner_key),
        0,
        null,
        0,
        w32.KEY_SET_VALUE,
        null,
        &key,
        null,
    ) != w32.ERROR_SUCCESS) {
        log.warn("PATH self-heal: could not open HKCU\\{s} to record the owned entry", .{owner_key});
        return;
    }
    defer _ = w32.RegCloseKey(key);
    const dir_w = std.unicode.utf8ToUtf16LeAllocZ(arena, dir) catch return;
    if (w32.RegSetValueExW(
        key,
        std.unicode.utf8ToUtf16LeStringLiteral(owner_value),
        0,
        w32.REG_SZ,
        @ptrCast(dir_w.ptr),
        @intCast((dir_w.len + 1) * 2),
    ) != w32.ERROR_SUCCESS) {
        log.warn("PATH self-heal: could not record the owned entry", .{});
    }
}
