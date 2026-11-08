//! Hands Claude's `ghoztty` integration over from the standalone plugin to
//! the app (T870, the win32 half of Mac's `ClaudePluginMigration.swift`):
//! the app now ships the same skills itself, tied to the installed Ghoztty
//! rather than to a separately-versioned marketplace release.
//!
//! The plugin is removed through **Claude's own CLI**, never by deleting
//! files out of `~/.claude/plugins/cache`. That tree is Claude Code's
//! package-manager state — it carries `.in_use`/`.orphaned_at` sentinels and
//! a versioned manifest whose schema is not ours — so deleting a directory
//! there leaves a dangling entry the next marketplace sync may act on, and
//! editing the manifest means writing another tool's lockfile. The CLI spawn
//! is injected (`Cli`), so the flow itself tests hermetically and the GUI
//! layer (`AgentIntegration.zig`) supplies the real `claude` invocation.
//!
//! Windows translation of the stale-script rule: Mac's plugin maintains
//! `~/.claude/scripts/ghoztty-banner.sh` as a SYMLINK into its own cache; on
//! Windows the plugin's SessionStart hook COPIES the script there instead
//! (measured on this box, 2026-08-15: a real file, byte-identical to the
//! plugin cache's copy). So ownership is proven two ways: a symlink whose
//! target points into `plugins/cache`, or a regular file byte-identical to
//! any registered ghoztty install's own copy. Anything else is the user's
//! and stays. The decision is taken BEFORE the uninstall runs, because
//! Claude's uninstaller may remove the very cache copy the comparison needs.
//!
//! Not one-shot (T2806, Mac's 2c9432071). The plugin can come back after the
//! hand-over (a marketplace sync or an old `dzearing-skills` dependency
//! reinstalled it, T1624), and even a DEAD registration closes
//! `RuntimeIntegration.isPluginManaged`: the app then writes nothing into
//! `~/.claude` and its skills freeze. So every launch runs `settleOnLaunch`,
//! which asks `claude plugin list --json` what still loads, uninstalls dead
//! registrations whatever the user answered, follows the recorded Switch/Keep
//! answer for a working plugin (asking once when there is none), clears the
//! retired marketplace and any orphaned `enabledPlugins` key, and refreshes an
//! outdated integration so skills and hooks track the running build.
//!
//! Plain `std.fs` + the manifest parser, no OS imports, so the tempdir tests
//! run in every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const claude_plugin_manifest = @import("claude_plugin_manifest.zig");
const InstallState = @import("managed_marker.zig").InstallState;

const log = std.log.scoped(.win32_claude);

/// Home-relative directory the plugin's banner hook keeps per-pane state in.
pub const plugin_state_sub_dir = ".claude/ghoztty-banner";

/// Home-relative directory the APP's banner script keeps the same state in
/// (see `hook_scripts.zig`: the bundled script spells this path itself).
pub const app_state_sub_dir = ".config/ghoztty/banner-state";

/// Home-relative path of the script copy/symlink the plugin maintained.
pub const plugin_script_sub_path = ".claude/scripts/ghoztty-banner.sh";

/// The plugin's own copy of the banner script, relative to a registration's
/// `installPath`.
pub const cache_script_rel_path = "hooks/ghoztty-banner.sh";

const max_script_bytes = 1024 * 1024;

pub const UninstallError = error{
    /// The claude CLI could not be run at all.
    ShellUnavailable,
    /// `claude plugin uninstall <registration>` exited nonzero.
    UninstallFailed,
    OutOfMemory,
};

/// The injected `claude` CLI seam (Mac's `runCommand` / `readCommand`
/// closures, as a context + function pointers because Zig has no capturing
/// closures). Arguments go to the CLI as an argv, never through a shell, so
/// a key read out of a JSON file reaches it as data.
pub const Cli = struct {
    ctx: ?*anyopaque = null,
    /// `claude <args>`: true when it ran and exited 0.
    runFn: *const fn (ctx: ?*anyopaque, args: []const []const u8) bool,
    /// `claude <args>` for its stdout (allocated in `arena`); null when it
    /// could not run or exited nonzero.
    readFn: *const fn (ctx: ?*anyopaque, arena: Allocator, args: []const []const u8) ?[]const u8,

    pub fn run(self: Cli, args: []const []const u8) bool {
        return self.runFn(self.ctx, args);
    }

    pub fn read(self: Cli, arena: Allocator, args: []const []const u8) ?[]const u8 {
        return self.readFn(self.ctx, arena, args);
    }
};

/// The app's own Claude integration, injected so tests stay out of the real
/// runtime probe (Mac's `integrationState` / `installIntegration`).
pub const Integration = struct {
    ctx: ?*anyopaque = null,
    stateFn: *const fn (ctx: ?*anyopaque) InstallState,
    installFn: *const fn (ctx: ?*anyopaque) void,
};

/// The user's answer to "Switch Over / Keep Plugin" (the `accepted` /
/// `declined` answer file). Null means it was never asked.
pub const Choice = enum { switched, kept };

/// Can a registration still load? Only Claude knows, so this comes from
/// `claude plugin list --json`.
pub const Health = enum {
    /// Permanently unloadable: it supplies no skills or hooks, so there is
    /// nothing here for a user's choice to protect.
    dead,
    live,
    /// Failing for a reason that may pass (no network, marketplace clone not
    /// fetched yet), or missing from the list. Never acted on.
    unknown,
};

pub const HealthEntry = struct { id: []const u8, health: Health };

/// The standalone plugin's own marketplace. Its repo is gone, so nothing
/// under it can ever recover, and while it stays registered `claude plugin
/// marketplace update` keeps cloning a repo that no longer exists.
pub const retired_marketplace = "ghoztty-claude-plugin";

/// Home-relative path of Claude's marketplace registry.
pub const known_marketplaces_sub_path = ".claude/plugins/known_marketplaces.json";

/// Home-relative path of Claude's user settings (`enabledPlugins`).
pub const settings_sub_path = ".claude/settings.json";

const max_json_bytes = 4 * 1024 * 1024;

/// Whether the migration has anything to do: the external plugin is
/// registered in Claude's manifest.
pub fn isNeeded(alloc: Allocator, home: std.fs.Dir) Allocator.Error!bool {
    return claude_plugin_manifest.isExternalPluginInstalled(alloc, home);
}

/// One launch's work, off the GUI thread. Returns true when the caller should
/// show the Switch Over / Keep Plugin offer.
///
/// Dead registrations go whatever the user answered: "Keep Plugin" kept a
/// plugin that worked, and a dead one has nothing left to keep. A plugin that
/// still loads is theirs to decide about, so it follows the recorded choice,
/// and with no recorded choice they are asked. `may_prompt` only holds the
/// offer back (the first-run offer is unanswered); the rest is silent, so it
/// runs regardless.
pub fn settleOnLaunch(
    alloc: Allocator,
    home: std.fs.Dir,
    choice: ?Choice,
    may_prompt: bool,
    cli: Cli,
    integration: Integration,
) Allocator.Error!bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const swept = try sweepLeftovers(arena, home, cli);
    var removed_plugin = swept.removed_plugin;

    if (swept.live.len > 0) {
        switch (choice orelse return may_prompt) {
            .kept => return false,
            // They chose to switch and it came back, so asking again would
            // only repeat the question. A failure retries next launch.
            .switched => {
                run(arena, home, cli) catch |err| {
                    log.warn("plugin settle: could not remove the returned plugin: {}", .{err});
                    return false;
                };
                removed_plugin = true;
            },
        }
    }

    // Anything left is `.unknown`: the gate is still closed, so wait.
    if ((try claude_plugin_manifest.registrations(arena, home)).len != 0) return false;
    refreshIntegration(integration, removed_plugin);
    return false;
}

pub const Swept = struct {
    removed_plugin: bool,
    /// Registrations still present that Claude reports as loading.
    live: []const []const u8,
};

/// Clears what no longer works and reports what still does. `arena` owns
/// the result.
pub fn sweepLeftovers(arena: Allocator, home: std.fs.Dir, cli: Cli) Allocator.Error!Swept {
    var removed_plugin = false;
    var health: []const HealthEntry = &.{};
    var remove_script = false;

    const found = try claude_plugin_manifest.registrationsWithPaths(arena, home);
    if (found.len > 0) {
        // Decided before any uninstall, which may clear the cache copy the
        // byte proof compares against (see the module doc).
        remove_script = scriptIsPluginOwned(arena, home, found);
        if (cli.read(arena, &.{ "plugin", "list", "--json" })) |out| {
            health = try parseHealth(arena, out);
        }
        for (found) |reg| {
            if (healthOf(health, reg.key) != .dead) continue;
            if (cli.run(&.{ "plugin", "uninstall", reg.key })) {
                removed_plugin = true;
                log.info("plugin settle: uninstalled dead registration {s}", .{reg.key});
            } else {
                log.warn("plugin settle: could not uninstall dead registration {s}", .{reg.key});
            }
        }
    }

    const left = try claude_plugin_manifest.registrations(arena, home);
    if (removed_plugin and left.len == 0) {
        migrateBannerState(home);
        if (remove_script) home.deleteFile(plugin_script_sub_path) catch {};
    }
    try clearRegistrationResidue(arena, home, cli);

    var live: std.ArrayList([]const u8) = .empty;
    for (left) |key| {
        if (healthOf(health, key) == .live) try live.append(arena, key);
    }
    return .{ .removed_plugin = removed_plugin, .live = live.items };
}

/// The two things `claude plugin uninstall` can leave behind. Best effort:
/// both are retried next launch, and neither blocks the integration.
pub fn clearRegistrationResidue(arena: Allocator, home: std.fs.Dir, cli: Cli) Allocator.Error!void {
    const left = try claude_plugin_manifest.registrations(arena, home);

    // Removing a marketplace also uninstalls every plugin under it, so it
    // waits until nothing the user may want is left there. Read from
    // `known_marketplaces.json` because the CLI cannot remove an entry that
    // only `extraKnownMarketplaces` declares (it exits `not_configured`).
    if (try retiredMarketplaceIsRegistered(arena, home)) {
        var still_used = false;
        for (left) |key| {
            if (isRetired(key)) still_used = true;
        }
        if (!still_used and !cli.run(&.{ "plugin", "marketplace", "remove", retired_marketplace })) {
            log.warn("plugin settle: could not remove the retired Claude marketplace", .{});
        }
    }

    // `uninstall` refuses a key with no manifest entry (`not_installed`), so
    // `disable` is the only CLI route. It leaves the key set to false, which
    // Claude ignores and this no longer matches.
    for (try orphanedEnabledKeys(arena, home, left)) |key| {
        if (!cli.run(&.{ "plugin", "disable", key, "--scope", "user" })) {
            log.warn("plugin settle: could not disable orphaned plugin key {s}", .{key});
        }
    }
}

/// Keeps the app's skills and hooks matching the running build, which is
/// what "the app owns them" means: nothing else ever refreshes them.
///
/// `.not_installed` is left alone unless a plugin was just removed. That is
/// how the panel's Uninstall reads, and a user who never set the integration
/// up did not ask for it. Removing the plugin is different: this is its
/// replacement. Silent, because a launch-time failure repeats every launch.
pub fn refreshIntegration(integration: Integration, removed_plugin: bool) void {
    const state = integration.stateFn(integration.ctx);
    const due = if (removed_plugin) state != .installed else state == .outdated;
    if (!due) return;
    integration.installFn(integration.ctx);
}

/// Health by registration, from `claude plugin list --json`. `arena` owns
/// the result (ids alias the parsed output).
///
/// `plugin-not-found` is the one permanent failure a marketplace reports.
/// Every other error may be transient, except under the retired marketplace,
/// where nothing can recover. Output that is not the expected array is the
/// empty list: nothing is then acted on.
pub fn parseHealth(arena: Allocator, output: []const u8) Allocator.Error![]const HealthEntry {
    const json = pluginEntriesSlice(output) orelse return &.{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    if (root != .array) return &.{};

    var out: std.ArrayList(HealthEntry) = .empty;
    for (root.array.items) |entry| {
        if (entry != .object) continue;
        const id_v = entry.object.get("id") orelse continue;
        if (id_v != .string) continue;
        const id = id_v.string;

        var not_found = false;
        var detail_count: usize = 0;
        if (entry.object.get("errorDetails")) |d| {
            if (d == .array) {
                detail_count = d.array.items.len;
                for (d.array.items) |item| {
                    if (item != .object) continue;
                    const t = item.object.get("type") orelse continue;
                    if (t == .string and std.mem.eql(u8, t.string, "plugin-not-found")) not_found = true;
                }
            }
        }
        var error_count: usize = 0;
        if (entry.object.get("errors")) |e| {
            if (e == .array) error_count = e.array.items.len;
        }

        const health: Health = if (not_found)
            .dead
        else if (detail_count == 0 and error_count == 0)
            .live
        else if (isRetired(id))
            .dead
        else
            .unknown;
        try out.append(arena, .{ .id = id, .health = health });
    }
    return out.items;
}

pub fn healthOf(entries: []const HealthEntry, id: []const u8) Health {
    for (entries) |e| {
        if (std.mem.eql(u8, e.id, id)) return e.health;
    }
    return .unknown;
}

fn isRetired(key: []const u8) bool {
    const m = claude_plugin_manifest.marketplaceOfRegistration(key) orelse return false;
    return std.mem.eql(u8, m, retired_marketplace);
}

/// The JSON array in the output, from the first line that opens it. Claude
/// runs here without a login shell, but a wrapper (an npm `.cmd` shim) may
/// still print ahead of it, so this keeps Mac's tolerance.
fn pluginEntriesSlice(output: []const u8) ?[]const u8 {
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "[") or std.mem.eql(u8, trimmed, "[]")) {
            return output[offset..];
        }
        offset += line.len + 1;
    }
    return null;
}

fn readJsonObject(arena: Allocator, home: std.fs.Dir, sub_path: []const u8) Allocator.Error!?std.json.ObjectMap {
    const contents = home.readFileAlloc(arena, sub_path, max_json_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, contents, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return if (root == .object) root.object else null;
}

fn retiredMarketplaceIsRegistered(arena: Allocator, home: std.fs.Dir) Allocator.Error!bool {
    const obj = (try readJsonObject(arena, home, known_marketplaces_sub_path)) orelse return false;
    return obj.get(retired_marketplace) != null;
}

/// `ghoztty` keys still enabled in `settings.json` with no manifest entry.
pub fn orphanedEnabledKeys(
    arena: Allocator,
    home: std.fs.Dir,
    installed: []const []const u8,
) Allocator.Error![]const []const u8 {
    const obj = (try readJsonObject(arena, home, settings_sub_path)) orelse return &.{};
    const enabled = obj.get("enabledPlugins") orelse return &.{};
    if (enabled != .object) return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    var it = enabled.object.iterator();
    outer: while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (v != .bool or !v.bool) continue;
        const name = claude_plugin_manifest.nameOfRegistration(key);
        if (!std.mem.eql(u8, name, claude_plugin_manifest.external_plugin_name)) continue;
        for (installed) |i| {
            if (std.mem.eql(u8, i, key)) continue :outer;
        }
        try out.append(arena, key);
    }
    return out.items;
}

/// Uninstall FIRST. Everything after it is cleanup that only makes sense
/// once the plugin is actually gone, so a failure here leaves the user
/// exactly where they started rather than half-migrated. The stale-script
/// ownership decision is the one thing taken BEFORE the uninstall (see the
/// module doc); acting on it still waits until the uninstall succeeded.
pub fn run(alloc: Allocator, home: std.fs.Dir, cli: Cli) UninstallError!void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const regs = try claude_plugin_manifest.registrationsWithPaths(arena, home);
    const remove_script = scriptIsPluginOwned(arena, home, regs);

    for (regs) |reg| {
        if (!cli.run(&.{ "plugin", "uninstall", reg.key })) return error.UninstallFailed;
    }

    migrateBannerState(home);
    if (remove_script) home.deleteFile(plugin_script_sub_path) catch {};
    try clearRegistrationResidue(arena, home, cli);
}

/// Carry the plugin's per-pane banner state into the app's state directory
/// so a pane mid-session keeps its banner instead of blanking until the next
/// prompt.
///
/// Copies rather than moves, and never overwrites: a file the app already
/// wrote is newer than anything the plugin left behind, and leaving the
/// originals in place means a user who reinstalls the plugin finds its state
/// where it expects. Best-effort throughout — a state file that cannot be
/// copied is a blank banner until the next prompt, never a failed migration.
pub fn migrateBannerState(home: std.fs.Dir) void {
    var src = home.openDir(plugin_state_sub_dir, .{ .iterate = true }) catch return;
    defer src.close();
    home.makePath(app_state_sub_dir) catch return;
    var dst = home.openDir(app_state_sub_dir, .{}) catch return;
    defer dst.close();

    var it = src.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (dst.statFile(entry.name)) |_| continue else |_| {}
        src.copyFile(entry.name, dst, entry.name, .{}) catch {};
    }
}

/// Is the script at `plugin_script_sub_path` provably the PLUGIN's, i.e.
/// ours to remove once the plugin is gone? See the module doc for the two
/// proofs. Everything else — a missing file, a link the user aimed
/// somewhere else, content the plugin cannot account for, or any read
/// failure — reads as "not ours": the cost of leaving a stale script is an
/// inert file, the cost of deleting the user's is their data.
pub fn scriptIsPluginOwned(
    arena: Allocator,
    home: std.fs.Dir,
    regs: []const claude_plugin_manifest.Registration,
) bool {
    // Symlink proof (the Mac rule): a link whose target points into the
    // plugin cache is the plugin's, dangling or not. Any readLink failure —
    // including the not-a-reparse-point case, which Zig's Windows ReadLink
    // surfaces as `error.Unexpected` rather than `error.NotLink` — falls
    // through to the byte proof, where a missing or unreadable file simply
    // reads as "not ours".
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (home.readLink(plugin_script_sub_path, &target_buf)) |target| {
        return symlinkTargetIsPluginCache(target);
    } else |_| {}

    // Byte proof (the Windows copy): identical to any registered install's
    // own copy of the script.
    const actual = home.readFileAlloc(arena, plugin_script_sub_path, max_script_bytes) catch
        return false;
    for (regs) |reg| {
        for (reg.install_paths) |install_path| {
            const candidate = std.fs.path.join(arena, &.{
                install_path, cache_script_rel_path,
            }) catch continue;
            const expected = std.fs.cwd().readFileAlloc(arena, candidate, max_script_bytes) catch
                continue;
            if (std.mem.eql(u8, actual, expected)) return true;
        }
    }
    return false;
}

/// The symlink half of the ownership proof, pure for tests (creating real
/// symlinks needs a privilege Windows test runs may lack). Both separators:
/// a Windows-created link may spell the cache path either way.
pub fn symlinkTargetIsPluginCache(target: []const u8) bool {
    return std.mem.indexOf(u8, target, "/plugins/cache/") != null or
        std.mem.indexOf(u8, target, "\\plugins\\cache\\") != null;
}

// -----------------------------------------------------------------------------
// Tests — the Mac migration table plus the Windows byte-proof cases, all
// against real files in tempdirs.
// -----------------------------------------------------------------------------

const testing = std.testing;

const test_script = "#!/bin/bash\necho plugin banner v0.8.0\n";

/// Registers one ghoztty install whose installPath points into the tempdir's
/// own plugin cache, and puts the script copy there.
fn writePluginFixture(tmp: *testing.TmpDir, alloc: Allocator) ![]const u8 {
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    const install_path = try std.fs.path.join(alloc, &.{
        root, ".claude", "plugins", "cache", "m", "ghoztty", "0.8.0",
    });
    try tmp.dir.makePath(".claude/plugins/cache/m/ghoztty/0.8.0/hooks");
    try tmp.dir.writeFile(.{
        .sub_path = ".claude/plugins/cache/m/ghoztty/0.8.0/hooks/ghoztty-banner.sh",
        .data = test_script,
    });
    const escaped = try std.mem.replaceOwned(u8, alloc, install_path, "\\", "\\\\");
    const manifest = try std.fmt.allocPrint(alloc,
        \\{{"version": 2, "plugins": {{"ghoztty@m": [{{"installPath": "{s}"}}]}}}}
    , .{escaped});
    try tmp.dir.makePath(".claude/plugins");
    try tmp.dir.writeFile(.{
        .sub_path = claude_plugin_manifest.manifest_sub_path,
        .data = manifest,
    });
    return install_path;
}

/// The fake `claude` CLI: records every call, answers `plugin list --json`
/// from `list_json`, and (with `home`) removes an uninstalled key from the
/// manifest the way Claude's own uninstaller does.
const RecordingCli = struct {
    alloc: Allocator,
    /// Every call, args joined by spaces.
    calls: std.ArrayList([]const u8) = .empty,
    /// Every registration `plugin uninstall` succeeded for.
    uninstalled: std.ArrayList([]const u8) = .empty,
    /// Every call fails.
    fail: bool = false,
    /// Only `plugin uninstall` fails.
    fail_uninstall: bool = false,
    /// `plugin list --json` output; null = the command fails.
    list_json: ?[]const u8 = null,
    /// When set, a successful uninstall drops the key from this home's manifest.
    home: ?std.fs.Dir = null,
    /// Simulates Claude's uninstaller clearing the cache copy: the byte
    /// proof must already have been decided by the time this runs.
    delete_cache_from: ?std.fs.Dir = null,

    fn cli(self: *RecordingCli) Cli {
        return .{ .ctx = self, .runFn = &runCall, .readFn = &readCall };
    }

    fn record(self: *RecordingCli, args: []const []const u8) void {
        const joined = std.mem.join(self.alloc, " ", args) catch return;
        self.calls.append(self.alloc, joined) catch self.alloc.free(joined);
    }

    fn runCall(ctx: ?*anyopaque, args: []const []const u8) bool {
        const self: *RecordingCli = @ptrCast(@alignCast(ctx.?));
        self.record(args);
        if (self.fail) return false;
        if (args.len == 3 and std.mem.eql(u8, args[1], "uninstall")) {
            if (self.fail_uninstall) return false;
            if (self.delete_cache_from) |dir| {
                dir.deleteFile(".claude/plugins/cache/m/ghoztty/0.8.0/hooks/ghoztty-banner.sh") catch {};
            }
            if (self.home) |home| removeManifestKey(self.alloc, home, args[2]) catch return false;
            const dup = self.alloc.dupe(u8, args[2]) catch return false;
            self.uninstalled.append(self.alloc, dup) catch {
                self.alloc.free(dup);
                return false;
            };
        }
        return true;
    }

    fn readCall(ctx: ?*anyopaque, arena: Allocator, args: []const []const u8) ?[]const u8 {
        const self: *RecordingCli = @ptrCast(@alignCast(ctx.?));
        self.record(args);
        if (self.fail) return null;
        const out = self.list_json orelse return null;
        return arena.dupe(u8, out) catch null;
    }

    fn called(self: *const RecordingCli, joined: []const u8) bool {
        for (self.calls.items) |c| {
            if (std.mem.eql(u8, c, joined)) return true;
        }
        return false;
    }

    fn deinit(self: *RecordingCli) void {
        for (self.calls.items) |item| self.alloc.free(item);
        self.calls.deinit(self.alloc);
        for (self.uninstalled.items) |item| self.alloc.free(item);
        self.uninstalled.deinit(self.alloc);
    }
};

fn removeManifestKey(alloc: Allocator, home: std.fs.Dir, key: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const contents = try home.readFileAlloc(arena, claude_plugin_manifest.manifest_sub_path, 1 << 20);
    var root = try std.json.parseFromSliceLeaky(std.json.Value, arena, contents, .{});
    if (root.object.getPtr("plugins")) |plugins| _ = plugins.object.orderedRemove(key);
    const out = try std.json.Stringify.valueAlloc(arena, root, .{});
    try home.writeFile(.{ .sub_path = claude_plugin_manifest.manifest_sub_path, .data = out });
}

const FakeIntegration = struct {
    state: InstallState,
    installs: usize = 0,

    fn integration(self: *FakeIntegration) Integration {
        return .{ .ctx = self, .stateFn = &stateCall, .installFn = &installCall };
    }

    fn stateCall(ctx: ?*anyopaque) InstallState {
        const self: *FakeIntegration = @ptrCast(@alignCast(ctx.?));
        return self.state;
    }

    fn installCall(ctx: ?*anyopaque) void {
        const self: *FakeIntegration = @ptrCast(@alignCast(ctx.?));
        self.installs += 1;
        self.state = .installed;
    }
};

const dead_list =
    \\[
    \\  {"id": "ghoztty@m", "errors": ["Plugin ghoztty not found in marketplace m"],
    \\   "errorDetails": [{"type": "plugin-not-found", "plugin": "ghoztty", "marketplace": "m"}]}
    \\]
;
const live_list =
    \\[
    \\  {"id": "ghoztty@m", "enabled": true}
    \\]
;
const transient_list =
    \\[
    \\  {"id": "ghoztty@m", "errors": ["network"], "errorDetails": [{"type": "marketplace-fetch-failed"}]}
    \\]
;

test "parseHealth: not-found is dead, clean is live, other errors unknown unless retired" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out =
        \\profile noise [not json]
        \\[
        \\  {"id": "ghoztty@a", "errorDetails": [{"type": "plugin-not-found"}]},
        \\  {"id": "ghoztty@b", "errors": [], "errorDetails": []},
        \\  {"id": "ghoztty@c", "errors": ["offline"]},
        \\  {"id": "ghoztty@ghoztty-claude-plugin", "errors": ["offline"]},
        \\  {"version": "no id"}
        \\]
    ;
    const h = try parseHealth(arena, out);
    try testing.expectEqual(@as(usize, 4), h.len);
    try testing.expectEqual(Health.dead, healthOf(h, "ghoztty@a"));
    try testing.expectEqual(Health.live, healthOf(h, "ghoztty@b"));
    try testing.expectEqual(Health.unknown, healthOf(h, "ghoztty@c"));
    try testing.expectEqual(Health.dead, healthOf(h, "ghoztty@ghoztty-claude-plugin"));
    try testing.expectEqual(Health.unknown, healthOf(h, "ghoztty@missing"));
}

test "parseHealth: output with no array, or not JSON, acts on nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(usize, 0), (try parseHealth(arena, "ok\n")).len);
    try testing.expectEqual(@as(usize, 0), (try parseHealth(arena, "[\n{broken")).len);
    try testing.expectEqual(@as(usize, 0), (try parseHealth(arena, "[]\n")).len);
    try testing.expectEqual(@as(usize, 0), (try parseHealth(arena, "")).len);
}

test "settle: a dead registration goes whatever the user answered, and the app takes over" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    try tmp.dir.makePath(".claude/scripts");
    try tmp.dir.writeFile(.{ .sub_path = plugin_script_sub_path, .data = test_script });
    try tmp.dir.makePath(plugin_state_sub_dir);
    try tmp.dir.writeFile(.{ .sub_path = plugin_state_sub_dir ++ "/pane-abc.json", .data = "{}" });

    inline for (.{ @as(?Choice, .kept), @as(?Choice, null) }) |choice| {
        var rec: RecordingCli = .{ .alloc = alloc, .list_json = dead_list, .home = tmp.dir };
        defer rec.deinit();
        var integ: FakeIntegration = .{ .state = .not_installed };
        _ = try writePluginFixture(&tmp, arena_state.allocator());
        try tmp.dir.writeFile(.{ .sub_path = plugin_script_sub_path, .data = test_script });

        try testing.expect(!try settleOnLaunch(alloc, tmp.dir, choice, true, rec.cli(), integ.integration()));
        try testing.expectEqual(@as(usize, 1), rec.uninstalled.items.len);
        try testing.expect(!try isNeeded(alloc, tmp.dir));
        // The replacement goes in even from not_installed: this IS the plugin's successor.
        try testing.expectEqual(@as(usize, 1), integ.installs);
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(plugin_script_sub_path));
        _ = try tmp.dir.statFile(app_state_sub_dir ++ "/pane-abc.json");
    }
}

test "settle: a live plugin with no recorded answer asks, only when it may" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());

    inline for (.{ true, false }) |may_prompt| {
        var rec: RecordingCli = .{ .alloc = alloc, .list_json = live_list, .home = tmp.dir };
        defer rec.deinit();
        var integ: FakeIntegration = .{ .state = .outdated };
        try testing.expectEqual(may_prompt, try settleOnLaunch(alloc, tmp.dir, null, may_prompt, rec.cli(), integ.integration()));
        try testing.expectEqual(@as(usize, 0), rec.uninstalled.items.len);
        try testing.expectEqual(@as(usize, 0), integ.installs);
    }
}

test "settle: Keep Plugin keeps a live plugin, silently" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());

    var rec: RecordingCli = .{ .alloc = alloc, .list_json = live_list, .home = tmp.dir };
    defer rec.deinit();
    var integ: FakeIntegration = .{ .state = .outdated };
    try testing.expect(!try settleOnLaunch(alloc, tmp.dir, .kept, true, rec.cli(), integ.integration()));
    try testing.expectEqual(@as(usize, 0), rec.uninstalled.items.len);
    try testing.expect(try isNeeded(alloc, tmp.dir));
    try testing.expectEqual(@as(usize, 0), integ.installs);
}

test "settle: Switch Over removes a plugin that came back, without asking again" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());

    var rec: RecordingCli = .{ .alloc = alloc, .list_json = live_list, .home = tmp.dir };
    defer rec.deinit();
    var integ: FakeIntegration = .{ .state = .installed };
    try testing.expect(!try settleOnLaunch(alloc, tmp.dir, .switched, true, rec.cli(), integ.integration()));
    try testing.expectEqual(@as(usize, 1), rec.uninstalled.items.len);
    try testing.expect(!try isNeeded(alloc, tmp.dir));
    // Already installed: nothing to replace.
    try testing.expectEqual(@as(usize, 0), integ.installs);
}

test "settle: a failed removal of a returned plugin retries next launch and refreshes nothing" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());

    var rec: RecordingCli = .{ .alloc = alloc, .list_json = live_list, .home = tmp.dir, .fail_uninstall = true };
    defer rec.deinit();
    var integ: FakeIntegration = .{ .state = .not_installed };
    try testing.expect(!try settleOnLaunch(alloc, tmp.dir, .switched, true, rec.cli(), integ.integration()));
    try testing.expect(try isNeeded(alloc, tmp.dir));
    try testing.expectEqual(@as(usize, 0), integ.installs);
}

test "settle: health Claude cannot vouch for is never acted on" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());

    // A transient error, and a list that failed outright.
    inline for (.{ @as(?[]const u8, transient_list), @as(?[]const u8, null) }) |list| {
        var rec: RecordingCli = .{ .alloc = alloc, .list_json = list, .home = tmp.dir };
        defer rec.deinit();
        var integ: FakeIntegration = .{ .state = .outdated };
        try testing.expect(!try settleOnLaunch(alloc, tmp.dir, .switched, true, rec.cli(), integ.integration()));
        try testing.expectEqual(@as(usize, 0), rec.uninstalled.items.len);
        try testing.expect(try isNeeded(alloc, tmp.dir));
        try testing.expectEqual(@as(usize, 0), integ.installs);
    }
}

test "settle: with no plugin, only an outdated integration is refreshed" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct { state: InstallState, installs: usize }{
        .{ .state = .outdated, .installs = 1 },
        .{ .state = .installed, .installs = 0 },
        // The panel's Uninstall reads like this, and a user who never set it
        // up did not ask for it.
        .{ .state = .not_installed, .installs = 0 },
    };
    for (cases) |c| {
        var rec: RecordingCli = .{ .alloc = alloc };
        defer rec.deinit();
        var integ: FakeIntegration = .{ .state = c.state };
        try testing.expect(!try settleOnLaunch(alloc, tmp.dir, null, true, rec.cli(), integ.integration()));
        try testing.expectEqual(c.installs, integ.installs);
        // Nothing registered: Claude is never even asked.
        try testing.expectEqual(@as(usize, 0), rec.calls.items.len);
    }
}

test "residue: the retired marketplace goes once nothing is left under it" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.makePath(".claude/plugins");
    try tmp.dir.writeFile(.{
        .sub_path = known_marketplaces_sub_path,
        .data = "{\"ghoztty-claude-plugin\": {}, \"other\": {}}",
    });
    // Still holding a registration (health unknown): the marketplace stays,
    // because removing it would uninstall that plugin too.
    try tmp.dir.writeFile(.{
        .sub_path = claude_plugin_manifest.manifest_sub_path,
        .data = "{\"version\": 2, \"plugins\": {\"ghoztty@ghoztty-claude-plugin\": [{}]}}",
    });
    {
        var rec: RecordingCli = .{ .alloc = alloc };
        defer rec.deinit();
        try clearRegistrationResidue(arena, tmp.dir, rec.cli());
        try testing.expect(!rec.called("plugin marketplace remove ghoztty-claude-plugin"));
    }
    try tmp.dir.writeFile(.{
        .sub_path = claude_plugin_manifest.manifest_sub_path,
        .data = "{\"version\": 2, \"plugins\": {}}",
    });
    {
        var rec: RecordingCli = .{ .alloc = alloc };
        defer rec.deinit();
        try clearRegistrationResidue(arena, tmp.dir, rec.cli());
        try testing.expect(rec.called("plugin marketplace remove ghoztty-claude-plugin"));
    }
}

test "residue: an enabled ghoztty key with no manifest entry is disabled, nothing else" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.makePath(".claude/plugins");
    try tmp.dir.writeFile(.{
        .sub_path = claude_plugin_manifest.manifest_sub_path,
        .data = "{\"version\": 2, \"plugins\": {\"ghoztty@kept\": [{}]}}",
    });
    try tmp.dir.writeFile(.{ .sub_path = settings_sub_path, .data =
        \\{"enabledPlugins": {
        \\  "ghoztty@orphan": true,
        \\  "ghoztty@kept": true,
        \\  "ghoztty@off": false,
        \\  "ghoztty-other@m": true,
        \\  "superpowers@dev": true
        \\}}
    });
    var rec: RecordingCli = .{ .alloc = alloc };
    defer rec.deinit();
    try clearRegistrationResidue(arena, tmp.dir, rec.cli());
    try testing.expectEqual(@as(usize, 1), rec.calls.items.len);
    try testing.expect(rec.called("plugin disable ghoztty@orphan --scope user"));
}

test "residue: unreadable settings and registry are quiet no-ops" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try tmp.dir.makePath(".claude/plugins");
    try tmp.dir.writeFile(.{ .sub_path = settings_sub_path, .data = "{not json" });
    try tmp.dir.writeFile(.{ .sub_path = known_marketplaces_sub_path, .data = "[]" });
    var rec: RecordingCli = .{ .alloc = alloc };
    defer rec.deinit();
    try clearRegistrationResidue(arena_state.allocator(), tmp.dir, rec.cli());
    try testing.expectEqual(@as(usize, 0), rec.calls.items.len);
}

test "isNeeded only when the ghoztty plugin is registered" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(!try isNeeded(alloc, tmp.dir));

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    try testing.expect(try isNeeded(alloc, tmp.dir));
}

test "run uninstalls every registration through the runner, then cleans up" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    // The plugin-maintained copy, byte-identical to the cache's.
    try tmp.dir.makePath(".claude/scripts");
    try tmp.dir.writeFile(.{ .sub_path = plugin_script_sub_path, .data = test_script });
    // One pane's state to carry over.
    try tmp.dir.makePath(plugin_state_sub_dir);
    try tmp.dir.writeFile(.{
        .sub_path = plugin_state_sub_dir ++ "/pane-abc.json",
        .data = "{\"title\": \"t\"}",
    });

    var rec: RecordingCli = .{ .alloc = alloc };
    defer rec.deinit();
    try run(alloc, tmp.dir, rec.cli());

    try testing.expectEqual(@as(usize, 1), rec.uninstalled.items.len);
    try testing.expectEqualStrings("ghoztty@m", rec.uninstalled.items[0]);
    // Banner state copied (originals left in place), stale script removed.
    const carried = try tmp.dir.readFileAlloc(alloc, app_state_sub_dir ++ "/pane-abc.json", 1024);
    defer alloc.free(carried);
    try testing.expectEqualStrings("{\"title\": \"t\"}", carried);
    _ = try tmp.dir.statFile(plugin_state_sub_dir ++ "/pane-abc.json");
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(plugin_script_sub_path));
}

test "a failed uninstall changes nothing" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    try tmp.dir.makePath(".claude/scripts");
    try tmp.dir.writeFile(.{ .sub_path = plugin_script_sub_path, .data = test_script });
    try tmp.dir.makePath(plugin_state_sub_dir);
    try tmp.dir.writeFile(.{ .sub_path = plugin_state_sub_dir ++ "/pane-abc.json", .data = "{}" });

    var rec: RecordingCli = .{ .alloc = alloc, .fail = true };
    defer rec.deinit();
    try testing.expectError(error.UninstallFailed, run(alloc, tmp.dir, rec.cli()));

    // Script and state untouched; nothing migrated.
    _ = try tmp.dir.statFile(plugin_script_sub_path);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(app_state_sub_dir ++ "/pane-abc.json"));
}

test "the byte proof is decided before the uninstall clears the cache copy" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    try tmp.dir.makePath(".claude/scripts");
    try tmp.dir.writeFile(.{ .sub_path = plugin_script_sub_path, .data = test_script });

    var rec: RecordingCli = .{ .alloc = alloc, .delete_cache_from = tmp.dir };
    defer rec.deinit();
    try run(alloc, tmp.dir, rec.cli());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(plugin_script_sub_path));
}

test "a script the plugin cannot account for is the user's and stays" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    try tmp.dir.makePath(".claude/scripts");
    try tmp.dir.writeFile(.{
        .sub_path = plugin_script_sub_path,
        .data = "#!/bin/bash\necho the user's own edit\n",
    });

    var rec: RecordingCli = .{ .alloc = alloc };
    defer rec.deinit();
    try run(alloc, tmp.dir, rec.cli());
    // Uninstalled, but the differing script survives.
    try testing.expectEqual(@as(usize, 1), rec.uninstalled.items.len);
    _ = try tmp.dir.statFile(plugin_script_sub_path);
}

test "migrateBannerState never overwrites the app's newer state" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(plugin_state_sub_dir);
    try tmp.dir.writeFile(.{ .sub_path = plugin_state_sub_dir ++ "/pane-a.json", .data = "old" });
    try tmp.dir.writeFile(.{ .sub_path = plugin_state_sub_dir ++ "/pane-b.json", .data = "carried" });
    try tmp.dir.writeFile(.{ .sub_path = plugin_state_sub_dir ++ "/notes.txt", .data = "not state" });
    try tmp.dir.makePath(app_state_sub_dir);
    try tmp.dir.writeFile(.{ .sub_path = app_state_sub_dir ++ "/pane-a.json", .data = "newer" });

    migrateBannerState(tmp.dir);

    const alloc = testing.allocator;
    const a = try tmp.dir.readFileAlloc(alloc, app_state_sub_dir ++ "/pane-a.json", 64);
    defer alloc.free(a);
    try testing.expectEqualStrings("newer", a);
    const b = try tmp.dir.readFileAlloc(alloc, app_state_sub_dir ++ "/pane-b.json", 64);
    defer alloc.free(b);
    try testing.expectEqualStrings("carried", b);
    // Only .json state files travel.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(app_state_sub_dir ++ "/notes.txt"));
}

test "migrateBannerState with no plugin state dir is a quiet no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    migrateBannerState(tmp.dir);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(app_state_sub_dir));
}

test "symlink targets: only plugins/cache paths count, either separator" {
    try testing.expect(symlinkTargetIsPluginCache("/Users/u/.claude/plugins/cache/m/ghoztty/1.0/hooks/ghoztty-banner.sh"));
    try testing.expect(symlinkTargetIsPluginCache("C:\\Users\\u\\.claude\\plugins\\cache\\m\\ghoztty\\1.0\\hooks\\ghoztty-banner.sh"));
    try testing.expect(!symlinkTargetIsPluginCache("/Users/u/.config/ghoztty/hooks/ghoztty-banner.sh"));
    try testing.expect(!symlinkTargetIsPluginCache(""));
}

test "scriptIsPluginOwned: absent script is not ours" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(!scriptIsPluginOwned(arena_state.allocator(), tmp.dir, &.{}));
}
