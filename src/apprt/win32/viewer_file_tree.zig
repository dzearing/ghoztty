//! The file tree a diff viewer pane's side panel renders (T464).
//!
//! The Windows port of Mac's `ViewerDiffTree.swift`: a pure transform from
//! git's flat list of changed paths into the rows on screen, kept out of the
//! window so the two behaviors that are easy to get subtly wrong — collapsing
//! a chain of single-child directories, and what a shut folder hides — are
//! asserted in the `none` lane without a card, a DC or a font.
//!
//! `ViewerTOCPanel.zig` paints these rows on the SAME card it paints a table
//! of contents on; the pane owns which of the two it is showing. That is the
//! factoring Mac arrived at (the diff tree landed in the same commit that cut
//! 217 lines out of `ViewerTOC.swift`), and it is why nothing here knows about
//! painting.
//!
//! ## Ownership
//!
//! A `Tree` owns every string it hands back — a row's id and its label are
//! duplicated out of the caller's file list rather than borrowed from it. The
//! pane rebuilds the tree from a fresh listing every poll, and a borrow would
//! be a use-after-free the first time a two-second working-tree poll dropped a
//! file whose row was still on screen.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const chrome_theme = @import("chrome_theme.zig");
const diff = @import("viewer_diff.zig");

/// The origins, in the order git status reads in — which is the order the
/// sections appear in the panel.
pub const section_order = [_]diff.Origin{ .committed, .staged, .unstaged, .untracked };

pub const Kind = enum {
    /// A working-tree section header ("Staged", "Changes", …). Only a
    /// `git-status:` diff ever has more than one; a commit or a range has
    /// none.
    section,
    /// A directory. Its title is the JOINED path of a collapsed chain
    /// (`src/apprt/win32`), which is why it is not just a name.
    folder,
    file,
};

pub const Row = struct {
    kind: Kind,
    /// Stable identity, owned. Sections: `section:<origin>`. Folders: the
    /// folder key, `<origin>:<path>`, which is what `collapsed` holds.
    /// Files: the file's path, which is what the pane's `diff_file` holds.
    id: []const u8,
    /// The label, owned. A file row's label is the BASENAME — the tree above
    /// it carries the rest.
    title: []const u8,
    depth: u8,
    /// For a `.file` row: the index into the `files` slice `build` was given.
    /// Kept for callers that want to reach back into their own list (the
    /// next/previous-file walk); nothing here needs it.
    file: usize = 0,
    /// For a `.file` row: everything the card draws beside the name, COPIED
    /// rather than borrowed. The probe rebuilds its entry list on a poll and
    /// frees the old paths with it, so a row holding a pointer into that list
    /// would be a use-after-free the first time a poll found nothing to
    /// redraw and the tree therefore was not rebuilt.
    status: diff.Status = .unknown,
    additions: u32 = 0,
    deletions: u32 = 0,
    binary: bool = false,
    /// For a `.folder` row: whether the user has clicked it shut.
    collapsed: bool = false,
    /// For a `.file` row in a FILTERED tree: the directory the file lives in,
    /// owned, empty at the repository root (T1336). Filtering flattens the
    /// tree, so the folder has to come back on the row itself — otherwise two
    /// same-named files in different folders are indistinguishable hits (Mac's
    /// `ViewerDiffPanel.fileRow` draws it as a second line for that reason).
    detail: []const u8 = "",
};

pub const Tree = struct {
    rows: []Row = &.{},
    alloc: Allocator,
    /// Whether a non-empty filter produced these rows: a flat hit list rather
    /// than the folder hierarchy.
    filtered: bool = false,
    /// How many files the listing had BEFORE the filter, so the card's header
    /// can say "3 of 120 files" rather than lose the size of the diff.
    total_files: usize = 0,

    pub fn deinit(self: *Tree) void {
        for (self.rows) |r| {
            self.alloc.free(r.id);
            self.alloc.free(r.title);
            if (r.detail.len > 0) self.alloc.free(r.detail);
        }
        if (self.rows.len > 0) self.alloc.free(self.rows);
        self.rows = &.{};
    }

    /// How many `.file` rows the tree is showing. What the pane's
    /// gutter/overlay policy counts, and what tells "one file, no tree worth
    /// drawing" from a diff worth navigating.
    pub fn fileRows(self: *const Tree) usize {
        var n: usize = 0;
        for (self.rows) |r| {
            if (r.kind == .file) n += 1;
        }
        return n;
    }
};

/// Build the rows for a file list.
///
/// `collapsed` is the set of folder keys the user has clicked shut; a key that
/// no longer names a folder is simply never consulted, so a stale entry left
/// behind by a poll that dropped a directory is harmless.
pub fn build(
    alloc: Allocator,
    files: []const diff.File,
    collapsed: []const []const u8,
) Allocator.Error!Tree {
    return buildFiltered(alloc, files, collapsed, "");
}

/// `build`, narrowed by the card's filter field (T1336; Mac's
/// `ViewerDiffTree.rows(for:filter:collapsed:)`).
///
/// `filter` is whitespace-separated terms, ALL of which must appear in a
/// file's path (or its pre-rename path), case-insensitively. A filter with any
/// term switches the tree to a FLAT list of the matching files, sorted by
/// path: when you are hunting for one file in a thousand, the folder structure
/// between you and it is in the way. The working-tree sections survive, with
/// counts of what matched, because "is it staged?" is still the question a
/// `git-status:` pane is asked. `collapsed` is not consulted while filtering —
/// a hit hidden inside a folder the reader shut an hour ago would be a hit the
/// filter found and then refused to show.
pub fn buildFiltered(
    alloc: Allocator,
    files: []const diff.File,
    collapsed: []const []const u8,
    filter: []const u8,
) Allocator.Error!Tree {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |r| {
            alloc.free(r.id);
            alloc.free(r.title);
            if (r.detail.len > 0) alloc.free(r.detail);
        }
        rows.deinit(alloc);
    }

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const filtered = isFiltering(filter);

    for (section_order) |origin| {
        // The indices of this section's files, in the order git listed them.
        var section: std.ArrayList(usize) = .empty;
        for (files, 0..) |f, i| {
            if (f.origin != origin) continue;
            if (filtered and !matches(f, filter)) continue;
            try section.append(arena, i);
        }
        if (section.items.len == 0) continue;

        var depth: u8 = 0;
        if (origin.sectionTitle()) |title| {
            const id = try std.fmt.allocPrint(alloc, "section:{s}", .{origin.name()});
            errdefer alloc.free(id);
            const label = try std.fmt.allocPrint(
                alloc,
                "{s} \u{00b7} {d}",
                .{ title, section.items.len },
            );
            errdefer alloc.free(label);
            try rows.append(alloc, .{
                .kind = .section,
                .id = id,
                .title = label,
                .depth = 0,
            });
            depth = 1;
        }

        if (filtered) {
            try appendHits(alloc, arena, &rows, files, section.items, depth);
            continue;
        }

        const root = try Node.create(arena);
        for (section.items) |i| try root.insert(arena, files[i].path, i);
        try flatten(alloc, arena, &rows, files, root, "", origin, depth, collapsed);
    }

    return .{
        .rows = try rows.toOwnedSlice(alloc),
        .alloc = alloc,
        .filtered = filtered,
        .total_files = files.len,
    };
}

// -------------------------------------------------------------------------
// Filtering (T1336)
// -------------------------------------------------------------------------

/// Whether `filter` holds any term at all. Whitespace alone is not a filter:
/// a stray space must not flatten the reader's tree.
pub fn isFiltering(filter: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, filter, &std.ascii.whitespace);
    return it.next() != null;
}

/// Does `f` match EVERY term of `filter`? Multiple terms all having to match
/// is what makes `viewer zig` a useful query rather than a literal one. The
/// pre-rename path counts too, so a renamed file is findable by either name.
///
/// Case is folded in ASCII only. Mac lowercases through Foundation, which
/// also folds accented letters; a path is overwhelmingly ASCII, and folding
/// UTF-8 byte-wise here would be wrong rather than merely incomplete.
pub fn matches(f: diff.File, filter: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, filter, &std.ascii.whitespace);
    while (it.next()) |term| {
        const in_path = std.ascii.indexOfIgnoreCase(f.path, term) != null;
        const in_old = if (f.old_path) |old|
            std.ascii.indexOfIgnoreCase(old, term) != null
        else
            false;
        if (!in_path and !in_old) return false;
    }
    return true;
}

/// One section's hits as flat file rows, ordered by their whole PATH (not
/// their basename — the folder is part of what the reader typed against).
fn appendHits(
    alloc: Allocator,
    arena: Allocator,
    rows: *std.ArrayList(Row),
    files: []const diff.File,
    indices: []const usize,
    depth: u8,
) Allocator.Error!void {
    const order = try arena.dupe(usize, indices);
    std.mem.sort(usize, order, files, struct {
        fn less(fs: []const diff.File, a: usize, b: usize) bool {
            return naturalLess(fs[a].path, fs[b].path);
        }
    }.less);
    for (order) |index| {
        const f = files[index];
        const id = try alloc.dupe(u8, f.path);
        errdefer alloc.free(id);
        const label = try alloc.dupe(u8, baseName(f.path));
        errdefer alloc.free(label);
        const detail: []const u8 = if (parentPath(f.path)) |p| try alloc.dupe(u8, p) else "";
        errdefer if (detail.len > 0) alloc.free(detail);
        try rows.append(alloc, .{
            .kind = .file,
            .id = id,
            .title = label,
            .depth = depth,
            .file = index,
            .status = f.status,
            .additions = f.additions,
            .deletions = f.deletions,
            .binary = f.binary,
            .detail = detail,
        });
    }
}

/// The first file row's `file` index — what Return in the filter opens (Mac's
/// `openFirstFilteredFile`), so "type a few letters and go" lands on the hit
/// at the top of the list the reader is looking at.
pub fn firstFile(rows: []const Row) ?usize {
    for (rows) |row| {
        if (row.kind == .file) return row.file;
    }
    return null;
}

// -------------------------------------------------------------------------
// Hierarchy
// -------------------------------------------------------------------------

/// A directory being built. Children keep insertion order; they are sorted at
/// flatten time, so the order git happened to list files in never leaks into
/// the display.
const Node = struct {
    names: std.ArrayList([]const u8) = .empty,
    kids: std.ArrayList(*Node) = .empty,
    files: std.ArrayList(usize) = .empty,

    fn create(arena: Allocator) Allocator.Error!*Node {
        const n = try arena.create(Node);
        n.* = .{};
        return n;
    }

    fn child(self: *Node, arena: Allocator, name: []const u8) Allocator.Error!*Node {
        for (self.names.items, self.kids.items) |existing, node| {
            if (std.mem.eql(u8, existing, name)) return node;
        }
        const node = try Node.create(arena);
        try self.names.append(arena, name);
        try self.kids.append(arena, node);
        return node;
    }

    fn insert(self: *Node, arena: Allocator, path: []const u8, index: usize) Allocator.Error!void {
        var node = self;
        var it = std.mem.splitScalar(u8, path, '/');
        var pending: ?[]const u8 = it.next();
        while (pending) |component| {
            const next = it.next();
            if (next == null) break; // the last component is the file itself
            if (component.len > 0) node = try node.child(arena, component);
            pending = next;
        }
        try node.files.append(arena, index);
    }
};

fn flatten(
    alloc: Allocator,
    arena: Allocator,
    rows: *std.ArrayList(Row),
    files: []const diff.File,
    node: *Node,
    prefix: []const u8,
    origin: diff.Origin,
    depth: u8,
    collapsed: []const []const u8,
) Allocator.Error!void {
    // Folders before files, each alphabetized the way a file browser would.
    const order = try arena.alloc(usize, node.names.items.len);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, node.names.items, struct {
        fn less(names: [][]const u8, a: usize, b: usize) bool {
            return naturalLess(names[a], names[b]);
        }
    }.less);

    for (order) |i| {
        // Collapse a chain of single-child directories into one row —
        // `src/apprt/win32` rather than three rows of indentation carrying no
        // information.
        var title = node.names.items[i];
        var path = if (prefix.len == 0)
            title
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, title });
        var current = node.kids.items[i];
        while (current.files.items.len == 0 and current.kids.items.len == 1) {
            const name = current.names.items[0];
            title = try std.fmt.allocPrint(arena, "{s}/{s}", .{ title, name });
            path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, name });
            current = current.kids.items[0];
        }

        const key = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ origin.name(), path });
        errdefer alloc.free(key);
        const label = try alloc.dupe(u8, title);
        errdefer alloc.free(label);
        const shut = contains(collapsed, key);
        try rows.append(alloc, .{
            .kind = .folder,
            .id = key,
            .title = label,
            .depth = depth,
            .collapsed = shut,
        });
        if (shut) continue;
        try flatten(alloc, arena, rows, files, current, path, origin, depth + 1, collapsed);
    }

    const file_order = try arena.alloc(usize, node.files.items.len);
    for (file_order, 0..) |*slot, i| slot.* = i;
    const Ctx = struct {
        files: []const diff.File,
        indices: []const usize,
        fn less(self: @This(), a: usize, b: usize) bool {
            return naturalLess(
                baseName(self.files[self.indices[a]].path),
                baseName(self.files[self.indices[b]].path),
            );
        }
    };
    std.mem.sort(
        usize,
        file_order,
        Ctx{ .files = files, .indices = node.files.items },
        Ctx.less,
    );

    for (file_order) |i| {
        const index = node.files.items[i];
        const id = try alloc.dupe(u8, files[index].path);
        errdefer alloc.free(id);
        const label = try alloc.dupe(u8, baseName(files[index].path));
        errdefer alloc.free(label);
        try rows.append(alloc, .{
            .kind = .file,
            .id = id,
            .title = label,
            .depth = depth,
            .file = index,
            .status = files[index].status,
            .additions = files[index].additions,
            .deletions = files[index].deletions,
            .binary = files[index].binary,
        });
    }
}

fn contains(set: []const []const u8, key: []const u8) bool {
    for (set) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// The file that comes next (or previous) after `current` in the tree the
/// reader is looking at — the answer "next change" needs once the open file
/// has no further hunk in that direction (T817). Returns the row's `file`
/// index, or null when there is nowhere to go.
///
/// The walk is over the tree's VISIBLE rows rather than the diff's whole file
/// list, so it follows what is on screen: a folder the reader clicked shut is
/// not somewhere the next-change button should land them (Mac walks
/// `visibleFiles` for the same reason). A `current` the tree is not showing —
/// its folder was collapsed while it was open — also answers null: moving on
/// from a file that is not in view would be a jump out of nowhere.
pub fn adjacentFile(rows: []const Row, current: []const u8, forward: bool) ?usize {
    var prev: ?usize = null;
    var at_current = false;
    for (rows) |row| {
        if (row.kind != .file) continue;
        if (at_current) return if (forward) row.file else null;
        if (std.mem.eql(u8, row.id, current)) {
            if (!forward) return prev; // null at the first file: nowhere back
            at_current = true;
            continue;
        }
        prev = row.file;
    }
    return null;
}

/// The last path component. `git` speaks forward slashes on every platform, so
/// this reads the same for a Windows repository as for a POSIX one.
pub fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// The directory part of a path, or null at the repository root. What a
/// flattened (filtered) row would show under the name; also what a tooltip
/// wants.
pub fn parentPath(path: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return path[0..i];
}

/// What a file's git status MEANS on the badge beside its name. A tone, never
/// a color: the card resolves it against its own fill (`chrome_theme.toneInk`
/// / `toneFill`), so the same meaning clears the same contrast floor on a
/// light page and a dark one.
///
/// Mac paints the same four groups (`ViewerDiffPanel.color(for:)`) — green for
/// an addition, red for a deletion, blue for a rename or copy, amber for a
/// modification — and anything git could not classify stays neutral rather
/// than borrowing a meaning it has not got.
pub fn statusTone(status: diff.Status) chrome_theme.Tone {
    return switch (status) {
        .added => .good,
        .deleted => .danger,
        .renamed, .copied => .info,
        .modified, .type_changed => .warn,
        .unmerged, .unknown => .neutral,
    };
}

/// Case-insensitive, digit-runs-compare-numerically ordering — the readable
/// half of Mac's `localizedStandardCompare`, which is what puts `T9.md` before
/// `T10.md` in a tracker directory instead of after it.
pub fn naturalLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = a[i];
        const cb = b[j];
        if (std.ascii.isDigit(ca) and std.ascii.isDigit(cb)) {
            var ei = i;
            while (ei < a.len and std.ascii.isDigit(a[ei])) ei += 1;
            var ej = j;
            while (ej < b.len and std.ascii.isDigit(b[ej])) ej += 1;
            const na = std.mem.trimLeft(u8, a[i..ei], "0");
            const nb = std.mem.trimLeft(u8, b[j..ej], "0");
            if (na.len != nb.len) return na.len < nb.len;
            if (!std.mem.eql(u8, na, nb)) return std.mem.lessThan(u8, na, nb);
            i = ei;
            j = ej;
            continue;
        }
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return la < lb;
        i += 1;
        j += 1;
    }
    if (a.len != b.len) return a.len < b.len;
    // Equal but for case: a stable, total order still has to pick one.
    return std.mem.lessThan(u8, a, b);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn file(path: []const u8, origin: diff.Origin) diff.File {
    return .{ .path = path, .status = .modified, .origin = origin };
}

fn expectRow(row: Row, kind: Kind, title: []const u8, depth: u8) !void {
    try testing.expectEqual(kind, row.kind);
    try testing.expectEqualStrings(title, row.title);
    try testing.expectEqual(depth, row.depth);
}

test "flat listing: files sorted, no folder rows" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("go.md", .committed),
        file("build.zig", .committed),
        file("CLAUDE.md", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 3), tree.rows.len);
    try expectRow(tree.rows[0], .file, "build.zig", 0);
    try expectRow(tree.rows[1], .file, "CLAUDE.md", 0);
    try expectRow(tree.rows[2], .file, "go.md", 0);
    try testing.expectEqual(@as(usize, 3), tree.fileRows());
}

test "folders come before files, and nest" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("README.md", .committed),
        file("src/main.zig", .committed),
        file("src/apprt.zig", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 4), tree.rows.len);
    try expectRow(tree.rows[0], .folder, "src", 0);
    try expectRow(tree.rows[1], .file, "apprt.zig", 1);
    try expectRow(tree.rows[2], .file, "main.zig", 1);
    try expectRow(tree.rows[3], .file, "README.md", 0);
}

test "a single-child directory chain collapses into one row" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/apprt/win32/ViewerPane.zig", .committed),
        file("src/apprt/win32/ViewerTOCPanel.zig", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 3), tree.rows.len);
    try expectRow(tree.rows[0], .folder, "src/apprt/win32", 0);
    try testing.expectEqualStrings("committed:src/apprt/win32", tree.rows[0].id);
    try expectRow(tree.rows[1], .file, "ViewerPane.zig", 1);
    try expectRow(tree.rows[2], .file, "ViewerTOCPanel.zig", 1);
}

test "a chain stops collapsing where the tree branches" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/apprt/win32/App.zig", .committed),
        file("src/apprt/gtk/App.zig", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try expectRow(tree.rows[0], .folder, "src/apprt", 0);
    try expectRow(tree.rows[1], .folder, "gtk", 1);
    try expectRow(tree.rows[2], .file, "App.zig", 2);
    try expectRow(tree.rows[3], .folder, "win32", 1);
    try expectRow(tree.rows[4], .file, "App.zig", 2);
}

test "a chain stops where a directory holds a file of its own" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("docs/design/notes.md", .committed),
        file("docs/README.md", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try expectRow(tree.rows[0], .folder, "docs", 0);
    try expectRow(tree.rows[1], .folder, "design", 1);
    try expectRow(tree.rows[2], .file, "notes.md", 2);
    try expectRow(tree.rows[3], .file, "README.md", 1);
}

test "a shut folder hides its whole subtree, and says it is shut" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/apprt/win32/App.zig", .committed),
        file("go.md", .committed),
    };
    const collapsed = [_][]const u8{"committed:src/apprt/win32"};
    var tree = try build(alloc, &files, &collapsed);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 2), tree.rows.len);
    try expectRow(tree.rows[0], .folder, "src/apprt/win32", 0);
    try testing.expect(tree.rows[0].collapsed);
    try expectRow(tree.rows[1], .file, "go.md", 0);
    // The hidden file is not a file row, so next/previous never steps onto
    // something the reader cannot see.
    try testing.expectEqual(@as(usize, 1), tree.fileRows());
}

test "a collapsed key that names nothing is ignored" {
    const alloc = testing.allocator;
    const files = [_]diff.File{file("src/main.zig", .committed)};
    const collapsed = [_][]const u8{"committed:docs/design"};
    var tree = try build(alloc, &files, &collapsed);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 2), tree.rows.len);
    try testing.expect(!tree.rows[0].collapsed);
}

test "working-tree sections, in git status order, with counts" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("c.txt", .untracked),
        file("a.txt", .unstaged),
        file("b.txt", .staged),
        file("d.txt", .staged),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try expectRow(tree.rows[0], .section, "Staged \u{00b7} 2", 0);
    try expectRow(tree.rows[1], .file, "b.txt", 1);
    try expectRow(tree.rows[2], .file, "d.txt", 1);
    try expectRow(tree.rows[3], .section, "Changes \u{00b7} 1", 0);
    try expectRow(tree.rows[4], .file, "a.txt", 1);
    try expectRow(tree.rows[5], .section, "Untracked \u{00b7} 1", 0);
    try expectRow(tree.rows[6], .file, "c.txt", 1);
    try testing.expectEqualStrings("section:staged", tree.rows[0].id);
}

test "a commit's diff has no section header at all" {
    const alloc = testing.allocator;
    const files = [_]diff.File{file("a.txt", .committed)};
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 1), tree.rows.len);
    try expectRow(tree.rows[0], .file, "a.txt", 0);
}

test "the same folder name in two sections gets two keys" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/a.zig", .staged),
        file("src/b.zig", .unstaged),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqualStrings("staged:src", tree.rows[1].id);
    try testing.expectEqualStrings("unstaged:src", tree.rows[4].id);
    // Shutting one leaves the other open — the key carries the origin for
    // exactly this reason.
    const collapsed = [_][]const u8{"staged:src"};
    var shut = try build(alloc, &files, &collapsed);
    defer shut.deinit();
    try testing.expectEqual(@as(usize, 1), shut.fileRows());
}

test "a file row's index reaches back into the caller's list" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("z.txt", .committed),
        file("a.txt", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 1), tree.rows[0].file);
    try testing.expectEqual(@as(usize, 0), tree.rows[1].file);
    try testing.expectEqualStrings("a.txt", files[tree.rows[0].file].path);
}

test "an empty listing is an empty tree, not a crash" {
    const alloc = testing.allocator;
    var tree = try build(alloc, &.{}, &.{});
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.rows.len);
    try testing.expectEqual(@as(usize, 0), tree.fileRows());
}

test "natural order: numbers compare as numbers, case is ignored" {
    try testing.expect(naturalLess("T9.md", "T10.md"));
    try testing.expect(!naturalLess("T10.md", "T9.md"));
    try testing.expect(naturalLess("apprt.zig", "Build.zig"));
    try testing.expect(naturalLess("T007.md", "T8.md"));
    try testing.expect(!naturalLess("a", "a"));
    // A total order: two spellings that differ only in case still order.
    try testing.expect(naturalLess("README.md", "readme.md"));
}

test "basename and parent" {
    try testing.expectEqualStrings("App.zig", baseName("src/apprt/App.zig"));
    try testing.expectEqualStrings("go.md", baseName("go.md"));
    try testing.expectEqualStrings("src/apprt", parentPath("src/apprt/App.zig").?);
    try testing.expect(parentPath("go.md") == null);
}

test "status tones: every git letter carries one meaning" {
    try testing.expectEqual(chrome_theme.Tone.good, statusTone(.added));
    try testing.expectEqual(chrome_theme.Tone.danger, statusTone(.deleted));
    try testing.expectEqual(chrome_theme.Tone.info, statusTone(.renamed));
    try testing.expectEqual(chrome_theme.Tone.info, statusTone(.copied));
    try testing.expectEqual(chrome_theme.Tone.warn, statusTone(.modified));
    try testing.expectEqual(chrome_theme.Tone.warn, statusTone(.type_changed));
    try testing.expectEqual(chrome_theme.Tone.neutral, statusTone(.unmerged));
    try testing.expectEqual(chrome_theme.Tone.neutral, statusTone(.unknown));
}

test "a status tone reads on the card, in both themes" {
    // The badge is drawn as ink over its own tint; both have to clear the
    // chrome floor against the card fill, which is what `toneInk` guarantees
    // and what a hand-picked RGB would not.
    const light = chrome_theme.Rgb{ .r = 0xF2, .g = 0xF2, .b = 0xF2 };
    const dark = chrome_theme.Rgb{ .r = 0x1C, .g = 0x1F, .b = 0x25 };
    for ([_]chrome_theme.Rgb{ light, dark }) |card| {
        for ([_]diff.Status{ .added, .deleted, .renamed, .modified, .unknown }) |st| {
            const ink = chrome_theme.toneInk(card, statusTone(st));
            const ratio = @import("color_math.zig").wcagContrastRatio(
                @import("color_math.zig").wcagLuminance(ink),
                @import("color_math.zig").wcagLuminance(card),
            );
            try testing.expect(ratio >= chrome_theme.ui_contrast_target - 0.01);
        }
    }
}

test "a file row copies the facts the card draws, rather than pointing at them" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        .{ .path = "a.txt", .status = .added, .origin = .committed, .additions = 12, .deletions = 3 },
        .{ .path = "b.bin", .status = .modified, .origin = .committed, .binary = true },
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    try testing.expectEqual(diff.Status.added, tree.rows[0].status);
    try testing.expectEqual(@as(u32, 12), tree.rows[0].additions);
    try testing.expectEqual(@as(u32, 3), tree.rows[0].deletions);
    try testing.expect(!tree.rows[0].binary);
    try testing.expect(tree.rows[1].binary);
}

test "T817: next/previous change walks to the adjacent VISIBLE file" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("README.md", .committed),
        file("src/main.zig", .committed),
        file("src/apprt.zig", .committed),
    };
    var tree = try build(alloc, &files, &.{});
    defer tree.deinit();

    // Reading order down the card: src/apprt.zig, src/main.zig, README.md.
    const first = tree.rows[1].id;
    const middle = tree.rows[2].id;
    const last = tree.rows[3].id;

    try testing.expectEqual(tree.rows[2].file, adjacentFile(tree.rows, first, true).?);
    try testing.expectEqual(tree.rows[3].file, adjacentFile(tree.rows, middle, true).?);
    try testing.expectEqual(tree.rows[1].file, adjacentFile(tree.rows, middle, false).?);
    try testing.expectEqual(tree.rows[2].file, adjacentFile(tree.rows, last, false).?);

    // Off either end is a no-op, never a wrap: the reader asked for the next
    // change and there is not one.
    try testing.expectEqual(@as(?usize, null), adjacentFile(tree.rows, last, true));
    try testing.expectEqual(@as(?usize, null), adjacentFile(tree.rows, first, false));

    // A file nothing in the tree names answers nothing rather than the head of
    // the list — a jump out of nowhere is worse than standing still.
    try testing.expectEqual(@as(?usize, null), adjacentFile(tree.rows, "nope.md", true));
}

test "T817: a shut folder's files are not somewhere next-change lands" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("README.md", .committed),
        file("src/main.zig", .committed),
    };
    // `src` collapsed: the card shows the folder row and README.md only, so
    // stepping off README.md backwards has nowhere to go — walking into a file
    // the reader cannot see in the card would be the jump this rule prevents.
    var tree = try build(alloc, &files, &.{"committed:src"});
    defer tree.deinit();

    var visible: usize = 0;
    for (tree.rows) |r| {
        if (r.kind == .file) visible += 1;
    }
    try testing.expectEqual(@as(usize, 1), visible);
    try testing.expectEqual(@as(?usize, null), adjacentFile(tree.rows, "README.md", false));
    try testing.expectEqual(@as(?usize, null), adjacentFile(tree.rows, "README.md", true));
}

test "T1336: a filter flattens the tree into a path-ordered hit list" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/apprt/win32/ViewerPane.zig", .committed),
        file("src/apprt/win32/viewer_file_tree.zig", .committed),
        file("docs/viewer.md", .committed),
        file("build.zig", .committed),
    };
    var tree = try buildFiltered(alloc, &files, &.{}, "viewer");
    defer tree.deinit();

    try testing.expect(tree.filtered);
    try testing.expectEqual(@as(usize, 4), tree.total_files);
    // No folder rows at all: every row is a hit, at the top level, ordered by
    // its whole path rather than its name.
    try testing.expectEqual(@as(usize, 3), tree.rows.len);
    try expectRow(tree.rows[0], .file, "viewer.md", 0);
    try expectRow(tree.rows[1], .file, "viewer_file_tree.zig", 0);
    try expectRow(tree.rows[2], .file, "ViewerPane.zig", 0);
    // The directory comes back on the row, since the tree that carried it is
    // gone.
    try testing.expectEqualStrings("docs", tree.rows[0].detail);
    try testing.expectEqualStrings("src/apprt/win32", tree.rows[1].detail);
}

test "T1336: every term must match, in any order, ignoring case" {
    const f = diff.File{ .path = "src/apprt/win32/ViewerPane.zig", .status = .modified, .origin = .committed };
    try testing.expect(matches(f, "pane"));
    try testing.expect(matches(f, "ZIG win32"));
    try testing.expect(matches(f, "  viewer   apprt "));
    try testing.expect(!matches(f, "viewer markdown"));
    // A term spanning a separator is still one substring of the path.
    try testing.expect(matches(f, "win32/viewer"));
}

test "T1336: a renamed file is found by its old name too" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        .{ .path = "docs/new-name.md", .old_path = "docs/old-name.md", .status = .renamed, .origin = .committed },
        file("README.md", .committed),
    };
    var tree = try buildFiltered(alloc, &files, &.{}, "old-name");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.rows.len);
    try expectRow(tree.rows[0], .file, "new-name.md", 0);
}

test "T1336: whitespace alone is not a filter" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/a.zig", .committed),
        file("src/b.zig", .committed),
    };
    var tree = try buildFiltered(alloc, &files, &.{}, "  \t ");
    defer tree.deinit();
    try testing.expect(!tree.filtered);
    // The ordinary tree: a folder row, then its two files.
    try testing.expectEqual(@as(usize, 3), tree.rows.len);
    try expectRow(tree.rows[0], .folder, "src", 0);
    try testing.expectEqualStrings("", tree.rows[1].detail);
}

test "T1336: a filter finds files inside folders the reader shut" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("README.md", .committed),
        file("src/main.zig", .committed),
    };
    var tree = try buildFiltered(alloc, &files, &.{"committed:src"}, "main");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.rows.len);
    try expectRow(tree.rows[0], .file, "main.zig", 0);
}

test "T1336: sections survive a filter, counting only their hits, and empty ones go" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("src/one.zig", .staged),
        file("src/two.zig", .unstaged),
        file("src/three.md", .unstaged),
        file("notes.txt", .untracked),
    };
    var tree = try buildFiltered(alloc, &files, &.{}, ".zig");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 4), tree.rows.len);
    try testing.expectEqual(Kind.section, tree.rows[0].kind);
    try expectRow(tree.rows[1], .file, "one.zig", 1);
    try testing.expectEqual(Kind.section, tree.rows[2].kind);
    // "Changes · 1", not "· 2": the count is of what the reader can see.
    try testing.expect(std.mem.endsWith(u8, tree.rows[2].title, "\u{00b7} 1"));
    try expectRow(tree.rows[3], .file, "two.zig", 1);
}

test "T1336: no hits is an empty tree, and Return has nothing to open" {
    const alloc = testing.allocator;
    const files = [_]diff.File{file("README.md", .committed)};
    var tree = try buildFiltered(alloc, &files, &.{}, "nothing-matches-this");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.rows.len);
    try testing.expectEqual(@as(usize, 1), tree.total_files);
    try testing.expectEqual(@as(?usize, null), firstFile(tree.rows));
}

test "T1336: Return opens the hit at the TOP of the list, not git's first file" {
    const alloc = testing.allocator;
    const files = [_]diff.File{
        file("zeta/viewer.zig", .committed),
        file("alpha/viewer.zig", .committed),
    };
    var tree = try buildFiltered(alloc, &files, &.{}, "viewer");
    defer tree.deinit();
    // alpha sorts first, and it is index 1 in the caller's list.
    try testing.expectEqual(@as(?usize, 1), firstFile(tree.rows));
}
