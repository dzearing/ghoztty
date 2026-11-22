//! T3352: the record of open RELAY windows that brings them back at the next
//! launch - the Windows-native counterpart of Mac's `RemoteSessionManifest`
//! (WP-D2, `macos/Sources/Features/Remote/RemoteSessionManifest.swift`).
//!
//! The local layout capture skips every cross-machine window
//! (`App.captureSessionLayout`), because a relay window's shells live on the FAR
//! agent and are re-attached by dialing it, not by asking this box's agent. Mac
//! keeps a separate list for exactly that, and so does this: one entry per open
//! relay window, saying where to dial (relay base + device) and what to ATTACH
//! to (the first pane's agent session id), plus what the window was called.
//!
//! Lifecycle (the same as Mac's):
//!
//!   - an entry is REGISTERED when a relay window opens (dial or restore), and
//!     its session id is filled in once the pane has opened its agent session;
//!   - it is REMOVED on a deliberate close (the user closes the window, a
//!     Disconnect, the remote shell exits);
//!   - it is KEPT when the app quits or the account signs out, so the next
//!     launch can re-attach.
//!
//! Restore is mark-don't-drain: `snapshotForRestore` only marks entries in
//! flight, and nothing leaves the file until each entry's fate is decided -
//! `register(.., replacing)` on success, `remove` when the session is gone,
//! `releaseRestore` when the machine could not be reached. A crash anywhere in
//! between leaves every undecided entry on disk for the next launch.
//!
//! Persistence is `%LOCALAPPDATA%\ghoztty\remote-windows[-debug][-<lineage>].json`,
//! the `session_layout.layoutPath` derivation with another stem, so a debug build
//! and the release never restore each other's windows. GUI thread only: the
//! restore worker never touches it, it reports back and the GUI thread decides.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const agent_lineage = @import("../../remote/agent_lineage.zig");
const atomic_write = @import("../../remote/agent/atomic_write.zig");

const log = std.log.scoped(.relay_manifest);

/// Bigger than any honest file by orders of magnitude; a file past it is not
/// ours to trust.
pub const max_file_bytes: usize = 1 << 20;

/// Hex of 16 random bytes: this record's identity, NOT the agent session id.
pub const Id = [32]u8;

/// One open (or restorable) relay window. All strings owned by the manifest.
pub const Entry = struct {
    id: []const u8,
    relay_base: []const u8,
    device: []const u8,
    /// The agent session to re-ATTACH to. Null until the pane has opened it; an
    /// entry that never got one is dropped at restore (nothing to attach to).
    session_id: ?[]const u8 = null,
    /// The machine's display name when the window was recorded.
    name: ?[]const u8 = null,
    /// `name` came from the caller (`+new-remote-window --name=`), so a
    /// directory rename never touches it (T1736, Mac `namePinned`).
    name_pinned: bool = false,
    /// The IPC target name the window was opened under, so a restored window
    /// stays addressable by `+read` / `+send-keys` / `+close --target=`.
    ipc_name: ?[]const u8 = null,
    /// The window-level title pin (`+rename`, the rename dialog), or null.
    window_title: ?[]const u8 = null,
    /// The pin was typed by the user rather than set by a script.
    title_by_user: bool = false,
};

/// What `register` records. Every slice is borrowed and duped.
pub const New = struct {
    relay_base: []const u8,
    device: []const u8,
    session_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    name_pinned: bool = false,
    ipc_name: ?[]const u8 = null,
    window_title: ?[]const u8 = null,
    title_by_user: bool = false,
};

const Slot = struct {
    entry: Entry,
    /// Handed to a restore that has not decided its fate yet. Never persisted.
    in_flight: bool = false,
};

const FileBody = struct {
    version: u32 = 1,
    windows: []const Entry = &.{},
};

pub const Manifest = struct {
    alloc: Allocator,
    slots: std.ArrayList(Slot) = .empty,
    /// Where `save` writes. Null keeps the manifest in memory (tests, or no
    /// `%LOCALAPPDATA%`).
    path: ?[]const u8 = null,

    /// Load the manifest at `path` (owned by the result). A missing file is an
    /// empty manifest; an unreadable or malformed one is logged and treated as
    /// empty too - a restore record is never a reason to fail a launch.
    pub fn load(alloc: Allocator, path: ?[]const u8) Manifest {
        var m: Manifest = .{ .alloc = alloc };
        const p = path orelse return m;
        m.path = alloc.dupe(u8, p) catch return m;
        const bytes = std.fs.cwd().readFileAlloc(alloc, p, max_file_bytes) catch |err| switch (err) {
            error.FileNotFound => return m,
            else => {
                log.warn("relay window record unreadable path={s} err={}", .{ p, err });
                return m;
            },
        };
        defer alloc.free(bytes);
        m.parseInto(bytes) catch |err| {
            log.warn("relay window record malformed, ignoring it path={s} err={}", .{ p, err });
            m.clearSlots();
        };
        return m;
    }

    fn parseInto(self: *Manifest, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(FileBody, self.alloc, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        for (parsed.value.windows) |e| {
            // An entry with nowhere to dial is not restorable by anyone.
            if (e.relay_base.len == 0 or e.device.len == 0 or e.id.len == 0) continue;
            const owned = try self.dupeEntry(e);
            self.slots.append(self.alloc, .{ .entry = owned }) catch |err| {
                freeEntry(self.alloc, owned);
                return err;
            };
        }
    }

    pub fn deinit(self: *Manifest) void {
        self.clearSlots();
        self.slots.deinit(self.alloc);
        if (self.path) |p| self.alloc.free(p);
        self.* = undefined;
    }

    fn clearSlots(self: *Manifest) void {
        for (self.slots.items) |s| freeEntry(self.alloc, s.entry);
        self.slots.clearRetainingCapacity();
    }

    pub fn count(self: *const Manifest) usize {
        return self.slots.items.len;
    }

    /// The entry with `id`, or null. Borrowed until the next mutation.
    pub fn find(self: *const Manifest, id: []const u8) ?*const Entry {
        const i = self.indexOf(id) orelse return null;
        return &self.slots.items[i].entry;
    }

    fn indexOf(self: *const Manifest, id: []const u8) ?usize {
        for (self.slots.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.entry.id, id)) return i;
        }
        return null;
    }

    /// Record a newly opened relay window and return its id. `replacing` is the
    /// entry a restore just superseded: it goes in the same write the new one
    /// lands in, so the session is never recorded zero times on disk.
    pub fn register(self: *Manifest, new: New, replacing: ?[]const u8) !Id {
        var id: Id = undefined;
        var raw: [16]u8 = undefined;
        std.crypto.random.bytes(&raw);
        _ = std.fmt.bufPrint(&id, "{x}", .{raw}) catch unreachable;

        const owned = try self.dupeEntry(.{
            .id = &id,
            .relay_base = new.relay_base,
            .device = new.device,
            .session_id = new.session_id,
            .name = new.name,
            .name_pinned = new.name_pinned and new.name != null,
            .ipc_name = new.ipc_name,
            .window_title = new.window_title,
            .title_by_user = new.title_by_user and new.window_title != null,
        });
        self.slots.append(self.alloc, .{ .entry = owned }) catch |err| {
            freeEntry(self.alloc, owned);
            return err;
        };
        if (replacing) |old| self.dropSlot(old);
        self.save();
        return id;
    }

    /// Record the agent session id once the pane knows it. Unknown ids and an
    /// unchanged value are no-ops (no write).
    pub fn setSessionId(self: *Manifest, id: []const u8, session_id: []const u8) void {
        const i = self.indexOf(id) orelse return;
        const e = &self.slots.items[i].entry;
        if (e.session_id) |old| if (std.mem.eql(u8, old, session_id)) return;
        const dup = self.alloc.dupe(u8, session_id) catch return;
        if (e.session_id) |old| self.alloc.free(old);
        e.session_id = dup;
        self.save();
    }

    /// Record the window-level title pin (null clears it).
    pub fn setTitle(self: *Manifest, id: []const u8, title: ?[]const u8, by_user: bool) void {
        const i = self.indexOf(id) orelse return;
        const e = &self.slots.items[i].entry;
        const want_user = by_user and title != null;
        if (optEql(e.window_title, title) and e.title_by_user == want_user) return;
        const dup = if (title) |t| (self.alloc.dupe(u8, t) catch return) else null;
        if (e.window_title) |old| self.alloc.free(old);
        e.window_title = dup;
        e.title_by_user = want_user;
        self.save();
    }

    /// A directory rename (T1418): every UNPINNED entry for `device` takes the
    /// new name, whether its window is open or waiting for a later launch.
    pub fn updateName(self: *Manifest, device: []const u8, name: []const u8) void {
        var changed = false;
        for (self.slots.items) |*s| {
            if (!std.mem.eql(u8, s.entry.device, device)) continue;
            if (s.entry.name_pinned) continue;
            if (optEql(s.entry.name, name)) continue;
            const dup = self.alloc.dupe(u8, name) catch continue;
            if (s.entry.name) |old| self.alloc.free(old);
            s.entry.name = dup;
            changed = true;
        }
        if (changed) self.save();
    }

    /// A deliberate close, or a restore that found the session gone. Unknown
    /// ids are a no-op.
    pub fn remove(self: *Manifest, id: []const u8) void {
        if (self.indexOf(id) == null) return;
        self.dropSlot(id);
        self.save();
    }

    fn dropSlot(self: *Manifest, id: []const u8) void {
        const i = self.indexOf(id) orelse return;
        const s = self.slots.orderedRemove(i);
        freeEntry(self.alloc, s.entry);
    }

    /// Deep copies of every entry not already being restored, each marked in
    /// flight. Free with `freeSnapshot`. Per returned entry the caller must
    /// eventually `register(.., replacing)`, `remove` or `releaseRestore`.
    pub fn snapshotForRestore(self: *Manifest, alloc: Allocator) ![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        errdefer freeSnapshot(alloc, out.items);
        defer out.deinit(alloc);
        for (self.slots.items) |s| {
            if (s.in_flight) continue;
            const dup = try dupeEntryWith(alloc, s.entry);
            out.append(alloc, dup) catch |err| {
                freeEntry(alloc, dup);
                return err;
            };
        }
        // Mark only once the whole copy succeeded, so a failed snapshot leaves
        // nothing stuck in flight.
        for (self.slots.items) |*s| s.in_flight = true;
        return out.toOwnedSlice(alloc);
    }

    /// The restore could not be attempted (relay unreachable, no credential):
    /// the entry stays recorded and a later launch tries again.
    pub fn releaseRestore(self: *Manifest, id: []const u8) void {
        const i = self.indexOf(id) orelse return;
        self.slots.items[i].in_flight = false;
    }

    pub fn isInFlight(self: *const Manifest, id: []const u8) bool {
        const i = self.indexOf(id) orelse return false;
        return self.slots.items[i].in_flight;
    }

    /// Serialize the persisted shape. Caller frees.
    pub fn serialize(self: *const Manifest, alloc: Allocator) ![]u8 {
        const list = try alloc.alloc(Entry, self.slots.items.len);
        defer alloc.free(list);
        for (self.slots.items, list) |s, *e| e.* = s.entry;
        return std.json.Stringify.valueAlloc(alloc, FileBody{ .windows = list }, .{
            .emit_null_optional_fields = false,
            .whitespace = .indent_2,
        });
    }

    /// Write the file (or delete it when empty). Failures are logged, never
    /// returned: losing the record costs a restore, not the running window.
    pub fn save(self: *const Manifest) void {
        const p = self.path orelse return;
        if (self.slots.items.len == 0) {
            std.fs.cwd().deleteFile(p) catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("relay window record delete failed path={s} err={}", .{ p, err }),
            };
            return;
        }
        const body = self.serialize(self.alloc) catch |err| {
            log.warn("relay window record serialize failed err={}", .{err});
            return;
        };
        defer self.alloc.free(body);
        atomic_write.writeChunks(self.alloc, p, &.{body}, .{}) catch |err| {
            log.warn("relay window record write failed path={s} err={}", .{ p, err });
        };
    }

    fn dupeEntry(self: *const Manifest, e: Entry) !Entry {
        return dupeEntryWith(self.alloc, e);
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn dupeOpt(alloc: Allocator, s: ?[]const u8) !?[]const u8 {
    const v = s orelse return null;
    if (v.len == 0) return null;
    return try alloc.dupe(u8, v);
}

fn dupeEntryWith(alloc: Allocator, e: Entry) !Entry {
    var out: Entry = .{
        .id = &.{},
        .relay_base = &.{},
        .device = &.{},
        .name_pinned = e.name_pinned,
        .title_by_user = e.title_by_user,
    };
    errdefer freeEntry(alloc, out);
    out.id = try alloc.dupe(u8, e.id);
    out.relay_base = try alloc.dupe(u8, e.relay_base);
    out.device = try alloc.dupe(u8, e.device);
    out.session_id = try dupeOpt(alloc, e.session_id);
    out.name = try dupeOpt(alloc, e.name);
    out.ipc_name = try dupeOpt(alloc, e.ipc_name);
    out.window_title = try dupeOpt(alloc, e.window_title);
    if (out.name == null) out.name_pinned = false;
    if (out.window_title == null) out.title_by_user = false;
    return out;
}

pub fn freeEntry(alloc: Allocator, e: Entry) void {
    if (e.id.len > 0) alloc.free(e.id);
    if (e.relay_base.len > 0) alloc.free(e.relay_base);
    if (e.device.len > 0) alloc.free(e.device);
    if (e.session_id) |s| alloc.free(s);
    if (e.name) |s| alloc.free(s);
    if (e.ipc_name) |s| alloc.free(s);
    if (e.window_title) |s| alloc.free(s);
}

pub fn freeSnapshot(alloc: Allocator, entries: []const Entry) void {
    for (entries) |e| freeEntry(alloc, e);
}

/// `%LOCALAPPDATA%\ghoztty\remote-windows[-debug][-<lineage>].json`. Caller
/// frees. Null when `%LOCALAPPDATA%` is unset.
pub fn manifestPath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    return pathIn(alloc, dir, builtin.mode == .Debug);
}

fn pathIn(alloc: Allocator, dir: []const u8, debug: bool) ?[]u8 {
    const stem = if (debug) "remote-windows-debug" else "remote-windows";
    var lineage_buf: [agent_lineage.max_len]u8 = undefined;
    const lineage = agent_lineage.fromEnv(&lineage_buf);
    var stem_buf: [64]u8 = undefined;
    const full_stem = agent_lineage.appendSuffix(&stem_buf, stem, lineage) catch stem;
    var name_buf: [80]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}.json", .{full_stem}) catch return null;
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

// ---------------------------------------------------------------------------
// Tests (none lane: pure, no Win32).

const testing = std.testing;

test "relay manifest: register, capture the session, remove on close" {
    var m = Manifest.load(testing.allocator, null);
    defer m.deinit();
    const id = try m.register(.{ .relay_base = "https://r", .device = "dev1", .name = "Box", .name_pinned = true, .ipc_name = "w" }, null);
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expect(m.find(&id).?.session_id == null);
    m.setSessionId(&id, "sid-1");
    try testing.expectEqualStrings("sid-1", m.find(&id).?.session_id.?);
    try testing.expect(m.find(&id).?.name_pinned);
    try testing.expectEqualStrings("w", m.find(&id).?.ipc_name.?);
    m.remove(&id);
    try testing.expectEqual(@as(usize, 0), m.count());
    m.remove(&id); // unknown id: no-op
}

test "relay manifest: a pin needs a name, a user title needs a title" {
    var m = Manifest.load(testing.allocator, null);
    defer m.deinit();
    const id = try m.register(.{ .relay_base = "b", .device = "d", .name_pinned = true, .title_by_user = true }, null);
    try testing.expect(!m.find(&id).?.name_pinned);
    try testing.expect(!m.find(&id).?.title_by_user);
    m.setTitle(&id, "Mine", true);
    try testing.expectEqualStrings("Mine", m.find(&id).?.window_title.?);
    try testing.expect(m.find(&id).?.title_by_user);
    m.setTitle(&id, null, true);
    try testing.expect(m.find(&id).?.window_title == null);
    try testing.expect(!m.find(&id).?.title_by_user);
}

test "relay manifest: a rename skips pinned entries" {
    var m = Manifest.load(testing.allocator, null);
    defer m.deinit();
    const a = try m.register(.{ .relay_base = "b", .device = "d", .name = "old" }, null);
    const p = try m.register(.{ .relay_base = "b", .device = "d", .name = "mine", .name_pinned = true }, null);
    const other = try m.register(.{ .relay_base = "b", .device = "e", .name = "old" }, null);
    m.updateName("d", "new");
    try testing.expectEqualStrings("new", m.find(&a).?.name.?);
    try testing.expectEqualStrings("mine", m.find(&p).?.name.?);
    try testing.expectEqualStrings("old", m.find(&other).?.name.?);
}

test "relay manifest: mark-don't-drain restore" {
    var m = Manifest.load(testing.allocator, null);
    defer m.deinit();
    const a = try m.register(.{ .relay_base = "b", .device = "d", .session_id = "s1" }, null);
    const gone = try m.register(.{ .relay_base = "b", .device = "d", .session_id = "s2" }, null);
    const away = try m.register(.{ .relay_base = "b", .device = "e", .session_id = "s3" }, null);

    const snap = try m.snapshotForRestore(testing.allocator);
    defer {
        freeSnapshot(testing.allocator, snap);
        testing.allocator.free(snap);
    }
    try testing.expectEqual(@as(usize, 3), snap.len);
    // Nothing left the record, and a second snapshot gets nothing.
    try testing.expectEqual(@as(usize, 3), m.count());
    const again = try m.snapshotForRestore(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqual(@as(usize, 0), again.len);

    // Success supersedes, a dead session goes, an unreachable machine stays.
    const fresh = try m.register(.{ .relay_base = "b", .device = "d", .session_id = "s1" }, &a);
    m.remove(&gone);
    m.releaseRestore(&away);
    try testing.expectEqual(@as(usize, 2), m.count());
    try testing.expect(m.find(&a) == null);
    try testing.expect(!m.isInFlight(&fresh));
    try testing.expect(!m.isInFlight(&away));
}

test "relay manifest: round trip through the file, empty deletes it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "remote-windows.json" });
    defer testing.allocator.free(path);

    var id: Id = undefined;
    {
        var m = Manifest.load(testing.allocator, path);
        defer m.deinit();
        try testing.expectEqual(@as(usize, 0), m.count());
        id = try m.register(.{
            .relay_base = "https://relay",
            .device = "dev",
            .session_id = "sid",
            .name = "Pinned",
            .name_pinned = true,
            .ipc_name = "agent-1",
            .window_title = "T",
            .title_by_user = true,
        }, null);
    }
    {
        var m = Manifest.load(testing.allocator, path);
        defer m.deinit();
        const e = m.find(&id).?;
        try testing.expectEqualStrings("https://relay", e.relay_base);
        try testing.expectEqualStrings("sid", e.session_id.?);
        try testing.expectEqualStrings("Pinned", e.name.?);
        try testing.expect(e.name_pinned);
        try testing.expectEqualStrings("agent-1", e.ipc_name.?);
        try testing.expectEqualStrings("T", e.window_title.?);
        try testing.expect(e.title_by_user);
        try testing.expect(!m.isInFlight(&id));
        m.remove(&id);
    }
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
}

test "relay manifest: a malformed file reads as empty, unknown fields are ignored" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "rw.json" });
    defer testing.allocator.free(path);

    try tmp.dir.writeFile(.{ .sub_path = "rw.json", .data = "{not json" });
    var bad = Manifest.load(testing.allocator, path);
    bad.deinit();

    try tmp.dir.writeFile(.{ .sub_path = "rw.json", .data =
        \\{"version":2,"future":true,"windows":[
        \\ {"id":"a","relay_base":"b","device":"d","session_id":"s","extra":1},
        \\ {"id":"b","relay_base":"","device":"d"}
        \\]}
    });
    var m = Manifest.load(testing.allocator, path);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expectEqualStrings("s", m.find("a").?.session_id.?);
}

test "relay manifest: debug and release paths differ" {
    const rel = pathIn(testing.allocator, "C:\\x", false).?;
    defer testing.allocator.free(rel);
    const dbg = pathIn(testing.allocator, "C:\\x", true).?;
    defer testing.allocator.free(dbg);
    try testing.expect(!std.mem.eql(u8, rel, dbg));
    try testing.expect(std.mem.endsWith(u8, dbg, "-debug.json") or std.mem.indexOf(u8, dbg, "-debug") != null);
}
