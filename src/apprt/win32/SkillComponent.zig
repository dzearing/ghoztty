//! Installs the bundled `ghoztty` and `process-feedback` skills into a
//! runtime's `skills/` directory (T867, the win32 half of Mac's
//! `SkillComponent`). Portable across runtimes: only the config dir differs.
//!
//! A skill is a DIRECTORY (main 71da9a680, T2318): `SKILL.md` plus the
//! reference files it tells the agent to read on demand
//! (`GhosttyAssets.skillFiles`). Every file carries the ownership marker, and
//! a marked file the bundle no longer ships is a stray: it reads as outdated
//! and the next install removes it, or a renamed reference file would linger
//! and the agent would read a stale copy. An unmarked file in the directory is
//! the user's and is never touched.
//!
//! Every write goes through the marker-guarded atomic writer, so a user's
//! own file at one of our paths is refused and survives byte-identical.
//! All files are rendered before any is written (a missing asset fails
//! before the first write — comptime-embedded here, so only OOM remains),
//! and a partial failure rolls back IN REVERSE ORDER the files this call
//! CREATED — one deliberate improvement over Mac, whose rollback removes
//! everything it wrote and thereby deletes a skill that was already
//! installed before the failing upgrade began.
//!
//! Plain `std.fs` + the T865 writer, no direct OS imports, so the tempdir
//! tests run in every app-runtime lane on both seats.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const marker_mod = @import("managed_marker.zig");
const managed_file = @import("managed_file.zig");
const GhosttyAssets = @import("GhosttyAssets.zig");
const runtime_agent = @import("runtime_agent.zig");

const SkillComponent = @This();

pub const RuntimeAgent = runtime_agent.RuntimeAgent;
pub const InstallState = marker_mod.InstallState;
pub const marker = marker_mod.html_comment;
pub const skill_names = GhosttyAssets.skill_names;

/// The runtime whose config dir receives the skills.
agent: RuntimeAgent,
/// The user's home directory (a tempdir in tests).
home: std.fs.Dir,

/// Home-relative directory of one skill.
fn skillDirPath(self: SkillComponent, alloc: Allocator, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/skills/{s}", .{ self.agent.configDirectoryName(), name });
}

/// Home-relative path of one file of a skill.
fn fileSubPath(self: SkillComponent, alloc: Allocator, name: []const u8, file: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/skills/{s}/{s}", .{
        self.agent.configDirectoryName(), name, file,
    });
}

/// The exact bytes an installed skill file must hold: the markdown the
/// Windows app installs plus the ownership marker line. Mac's composition
/// (`asset + "\n" + marker + "\n"`), over the Windows wording of the asset
/// (T1327), so an install from before that wording reads as outdated and is
/// rewritten by the next upgrade.
fn expectedText(alloc: Allocator, name: []const u8, file: GhosttyAssets.SkillFile) Allocator.Error![]u8 {
    const body = try GhosttyAssets.installedSkillFile(alloc, name, file);
    defer alloc.free(body);
    return std.mem.concat(alloc, u8, &.{ body, "\n", marker, "\n" });
}

/// The files the bundle ships for `name` (names come from `skill_names`).
fn shippedFiles(name: []const u8) []const GhosttyAssets.SkillFile {
    return GhosttyAssets.skillFiles(name) catch unreachable;
}

fn isShipped(shipped: []const GhosttyAssets.SkillFile, entry: []const u8) bool {
    for (shipped) |file| {
        // NTFS is case-insensitive: `Layout.md` IS our `layout.md` there.
        const same = if (builtin.os.tag == .windows)
            std.ascii.eqlIgnoreCase(file.path, entry)
        else
            std.mem.eql(u8, file.path, entry);
        if (same) return true;
    }
    return false;
}

const PathList = std.ArrayListUnmanaged([]u8);

fn freePaths(alloc: Allocator, list: *PathList) void {
    for (list.items) |p| alloc.free(p);
    list.deinit(alloc);
}

/// Home-relative paths of the marked files in `name`'s installed directory
/// that the bundle does not ship: what an earlier version installed and this
/// one dropped. With `all`, every marked file (uninstall). Unmarked files,
/// links and subdirectories are never listed. Caller frees with `freePaths`.
fn strays(self: SkillComponent, alloc: Allocator, name: []const u8, all: bool) Allocator.Error!PathList {
    var out: PathList = .empty;
    errdefer freePaths(alloc, &out);
    const dir_sub = try self.skillDirPath(alloc, name);
    defer alloc.free(dir_sub);
    var dir = self.home.openDir(dir_sub, .{ .iterate = true }) catch return out;
    defer dir.close();
    const shipped = shippedFiles(name);
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!all and isShipped(shipped, entry.name)) continue;
        const contents = dir.readFileAlloc(alloc, entry.name, managed_file.max_managed_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue, // unreadable or over-cap: not provably ours
        };
        defer alloc.free(contents);
        if (!marker_mod.isManaged(contents, marker)) continue;
        try out.append(alloc, try self.fileSubPath(alloc, name, entry.name));
    }
    return out;
}

/// Aggregate install state over every file of every skill: all installed →
/// installed; all absent → not_installed; any mix, or any stray → outdated
/// (actionable). An allocation failure reads as outdated — the safe,
/// actionable answer.
pub fn state(self: SkillComponent, alloc: Allocator) InstallState {
    var saw_installed = false;
    var saw_missing = false;
    var saw_outdated = false;
    inline for (skill_names) |name| {
        for (shippedFiles(name)) |file| {
            const one = self.fileState(alloc, name, file) catch .outdated;
            switch (one) {
                .installed => saw_installed = true,
                .not_installed => saw_missing = true,
                .outdated => saw_outdated = true,
            }
        }
        if (self.strays(alloc, name, false)) |found| {
            var list = found;
            defer freePaths(alloc, &list);
            if (list.items.len > 0) saw_outdated = true;
        } else |_| saw_outdated = true;
    }
    if (saw_outdated or (saw_installed and saw_missing)) return .outdated;
    return if (saw_installed) .installed else .not_installed;
}

fn fileState(self: SkillComponent, alloc: Allocator, name: []const u8, file: GhosttyAssets.SkillFile) Allocator.Error!InstallState {
    const sub = try self.fileSubPath(alloc, name, file.path);
    defer alloc.free(sub);
    const want = try expectedText(alloc, name, file);
    defer alloc.free(want);
    return managed_file.state(alloc, self.home, sub, want, marker);
}

pub const InstallError = managed_file.WriteError;

/// Install every file of every skill, or nothing: on a partial failure the
/// files THIS call created are removed again in reverse order (see module
/// doc), and the original error is returned. A file that already existed
/// managed keeps the freshly written content — it stays ours and a retry
/// converges it. After a complete write, each skill's strays are removed.
pub fn install(self: SkillComponent, alloc: Allocator) InstallError!void {
    const Planned = struct { sub: []u8, body: []u8, created: bool = false };

    // Render all up front so any failure lands before the first write.
    var plan: std.ArrayListUnmanaged(Planned) = .empty;
    defer {
        for (plan.items) |p| {
            alloc.free(p.sub);
            alloc.free(p.body);
        }
        plan.deinit(alloc);
    }
    inline for (skill_names) |name| {
        for (shippedFiles(name)) |file| {
            const sub = try self.fileSubPath(alloc, name, file.path);
            errdefer alloc.free(sub);
            const body = try expectedText(alloc, name, file);
            errdefer alloc.free(body);
            try plan.append(alloc, .{ .sub = sub, .body = body });
        }
    }

    for (plan.items, 0..) |*p, i| {
        // Absent before the write (an unmarked file would fail the write, so
        // a successful write from .not_installed means we created the file).
        const pre = managed_file.state(alloc, self.home, p.sub, p.body, marker);
        managed_file.write(alloc, self.home, p.sub, p.body, marker) catch |err| {
            var j = i;
            while (j > 0) {
                j -= 1;
                if (plan.items[j].created)
                    managed_file.removeIfManaged(alloc, self.home, plan.items[j].sub, marker) catch {};
            }
            // A skill directory left empty by the rollback goes too;
            // deleteDir refuses one that still holds anything.
            inline for (skill_names) |name| {
                if (self.skillDirPath(alloc, name)) |dir_sub| {
                    defer alloc.free(dir_sub);
                    self.home.deleteDir(dir_sub) catch {};
                } else |_| {}
            }
            return err;
        };
        p.created = pre == .not_installed;
    }

    inline for (skill_names) |name| {
        var list = try self.strays(alloc, name, false);
        defer freePaths(alloc, &list);
        for (list.items) |sub| {
            managed_file.removeIfManaged(alloc, self.home, sub, marker) catch |err| switch (err) {
                // Lost its marker between the scan and the delete: the user's.
                error.NotManaged => {},
                error.RemoveFailed => return error.WriteFailed,
            };
        }
    }
}

pub const UninstallError = managed_file.RemoveError || Allocator.Error;

/// Remove every managed file of every skill, strays included, and each skill
/// directory left empty. A user's own file at one of the shipped paths is a
/// typed refusal and stops the pass (nothing of theirs is touched); one of
/// theirs elsewhere in the directory keeps the directory.
pub fn uninstall(self: SkillComponent, alloc: Allocator) UninstallError!void {
    inline for (skill_names) |name| {
        for (shippedFiles(name)) |file| {
            const sub = try self.fileSubPath(alloc, name, file.path);
            defer alloc.free(sub);
            try managed_file.removeIfManaged(alloc, self.home, sub, marker);
        }
        var list = try self.strays(alloc, name, true);
        defer freePaths(alloc, &list);
        for (list.items) |sub| try managed_file.removeIfManaged(alloc, self.home, sub, marker);
        const dir_sub = try self.skillDirPath(alloc, name);
        defer alloc.free(dir_sub);
        self.home.deleteDir(dir_sub) catch {};
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn testComponent(tmp: *testing.TmpDir) SkillComponent {
    return .{ .agent = .claude, .home = tmp.dir };
}

test "fresh install writes both skills marker-stamped and reports installed" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try testing.expectEqual(InstallState.not_installed, c.state(alloc));
    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));

    inline for (skill_names) |name| {
        const got = try tmp.dir.readFileAlloc(
            alloc,
            ".claude/skills/" ++ name ++ "/SKILL.md",
            managed_file.max_managed_bytes,
        );
        defer alloc.free(got);
        try testing.expect(std.mem.indexOf(u8, got, marker) != null);
        try testing.expect(std.mem.endsWith(u8, got, "\n" ++ marker ++ "\n"));
    }
}

test "the installed ghoztty skill is the Windows wording, not the Mac one" {
    // T1327: the file an agent actually reads, read back off disk. The bundled
    // asset is the Mac-worded shared document; what lands must carry none of
    // its Mac-only phrases.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);
    try c.install(alloc);

    // The banner editor chord lives in a reference file since main split the
    // skill (71da9a680); the core is checked by the directory test below.
    const got = try tmp.dir.readFileAlloc(alloc, ".claude/skills/ghoztty/banners-and-links.md", managed_file.max_managed_bytes);
    defer alloc.free(got);
    for (@import("skill_rewrite.zig").mac_only_phrases) |phrase| {
        try testing.expect(std.mem.indexOf(u8, got, phrase) == null);
    }
    try testing.expect(std.mem.indexOf(u8, got, "Ctrl+Shift+B") != null);
    var shared: ?[]const u8 = null;
    for (try GhosttyAssets.skillFiles("ghoztty")) |file| {
        if (std.mem.eql(u8, file.path, "banners-and-links.md")) shared = file.contents;
    }
    try testing.expect(std.mem.indexOf(u8, shared.?, "Cmd+R") != null); // the control
}

test "copilot component installs under .copilot, not .claude" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: SkillComponent = .{ .agent = .copilot, .home = tmp.dir };

    try c.install(alloc);
    _ = try tmp.dir.statFile(".copilot/skills/ghoztty/SKILL.md");
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".claude/skills/ghoztty/SKILL.md"));
}

test "hand-edited but still-marked skill reports outdated; reinstall converges" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try c.install(alloc);
    try tmp.dir.writeFile(.{
        .sub_path = ".claude/skills/ghoztty/SKILL.md",
        .data = "# tweaked by hand\n" ++ marker ++ "\n",
    });
    try testing.expectEqual(InstallState.outdated, c.state(alloc));

    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));
}

test "a user's own unmarked SKILL.md refuses install and survives byte-identical" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    const users_own = "# my very own skill\n";
    try tmp.dir.makePath(".claude/skills/ghoztty");
    try tmp.dir.writeFile(.{ .sub_path = ".claude/skills/ghoztty/SKILL.md", .data = users_own });

    try testing.expectError(error.NotManaged, c.install(alloc));

    const after = try tmp.dir.readFileAlloc(
        alloc,
        ".claude/skills/ghoztty/SKILL.md",
        managed_file.max_managed_bytes,
    );
    defer alloc.free(after);
    try testing.expectEqualStrings(users_own, after);
    // A mix of "user file blocks one skill" and "nothing of ours installed"
    // must read as not_installed, never installed.
    try testing.expectEqual(InstallState.not_installed, c.state(alloc));
}

test "failure on the second skill rolls back the first" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    // User's own file at the SECOND install path (skill_names order).
    const users_own = "# mine, hands off\n";
    try tmp.dir.makePath(".claude/skills/process-feedback");
    try tmp.dir.writeFile(.{ .sub_path = ".claude/skills/process-feedback/SKILL.md", .data = users_own });

    try testing.expectError(error.NotManaged, c.install(alloc));

    // The first skill was created by the failing call, so it was removed.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".claude/skills/ghoztty/SKILL.md"));
    const after = try tmp.dir.readFileAlloc(
        alloc,
        ".claude/skills/process-feedback/SKILL.md",
        managed_file.max_managed_bytes,
    );
    defer alloc.free(after);
    try testing.expectEqualStrings(users_own, after);
}

test "rollback never removes a skill that was installed before the call" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    // First skill installed by an earlier, successful run…
    try c.install(alloc);
    // …then the second skill's file is replaced by the user's own.
    try tmp.dir.deleteFile(".claude/skills/process-feedback/SKILL.md");
    try tmp.dir.writeFile(.{
        .sub_path = ".claude/skills/process-feedback/SKILL.md",
        .data = "# mine now\n",
    });

    try testing.expectError(error.NotManaged, c.install(alloc));

    // The pre-existing managed skill must survive the rollback.
    const got = try tmp.dir.readFileAlloc(
        alloc,
        ".claude/skills/ghoztty/SKILL.md",
        managed_file.max_managed_bytes,
    );
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, marker) != null);
}

test "uninstall removes exactly the marked files and leaves user files" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try c.install(alloc);
    // A user file elsewhere in the skills tree is untouched by uninstall.
    try tmp.dir.makePath(".claude/skills/my-skill");
    try tmp.dir.writeFile(.{ .sub_path = ".claude/skills/my-skill/SKILL.md", .data = "# mine\n" });

    try c.uninstall(alloc);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".claude/skills/ghoztty/SKILL.md"));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".claude/skills/process-feedback/SKILL.md"));
    _ = try tmp.dir.statFile(".claude/skills/my-skill/SKILL.md");
    try testing.expectEqual(InstallState.not_installed, c.state(alloc));

    // Uninstalling again over nothing is a no-op, not an error.
    try c.uninstall(alloc);
}

test "state aggregation: one installed + one absent reads outdated" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try c.install(alloc);
    try tmp.dir.deleteFile(".claude/skills/process-feedback/SKILL.md");
    try testing.expectEqual(InstallState.outdated, c.state(alloc));
}

test "a skill is its directory: every reference file lands marked and goes with it" {
    // Main 71da9a680: the reference files SKILL.md points the agent at are
    // installed beside it, each with the marker, and an uninstall that empties
    // the directory removes the directory too.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try c.install(alloc);
    const files = try GhosttyAssets.skillFiles("ghoztty");
    try testing.expect(files.len > 1);
    for (files) |file| {
        const sub = try std.fmt.allocPrint(alloc, ".claude/skills/ghoztty/{s}", .{file.path});
        defer alloc.free(sub);
        const got = try tmp.dir.readFileAlloc(alloc, sub, managed_file.max_managed_bytes);
        defer alloc.free(got);
        try testing.expect(std.mem.endsWith(u8, got, "\n" ++ marker ++ "\n"));
        // The Windows wording reaches the reference files, not just the core.
        for (@import("skill_rewrite.zig").mac_only_phrases) |phrase| {
            try testing.expect(std.mem.indexOf(u8, got, phrase) == null);
        }
    }

    try c.uninstall(alloc);
    try testing.expectError(error.FileNotFound, tmp.dir.access(".claude/skills/ghoztty", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(".claude/skills/process-feedback", .{}));
}

test "an update removes a managed file the bundle no longer ships and keeps the user's" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));
    try tmp.dir.writeFile(.{
        .sub_path = ".claude/skills/ghoztty/old-reference.md",
        .data = "old\n" ++ marker ++ "\n",
    });
    try tmp.dir.writeFile(.{ .sub_path = ".claude/skills/ghoztty/my-notes.md", .data = "my own notes" });
    // A stray reads as outdated, so the app offers the update that prunes it.
    try testing.expectEqual(InstallState.outdated, c.state(alloc));

    try c.install(alloc);
    try testing.expectError(error.FileNotFound, tmp.dir.access(".claude/skills/ghoztty/old-reference.md", .{}));
    _ = try tmp.dir.statFile(".claude/skills/ghoztty/my-notes.md");
    try testing.expectEqual(InstallState.installed, c.state(alloc));

    // Uninstall takes everything of ours and leaves the user's file, so the
    // directory that still holds it stays.
    try c.uninstall(alloc);
    _ = try tmp.dir.statFile(".claude/skills/ghoztty/my-notes.md");
    try testing.expectError(error.FileNotFound, tmp.dir.access(".claude/skills/ghoztty/SKILL.md", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(".claude/skills/ghoztty/layout.md", .{}));
}

test "an install from before the split (core only) reads outdated and converges" {
    // The shape every existing Windows install is in on upgrade: a marked
    // SKILL.md and none of the reference files.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try c.install(alloc);
    try tmp.dir.deleteFile(".claude/skills/ghoztty/layout.md");
    try testing.expectEqual(InstallState.outdated, c.state(alloc));
    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));
}
