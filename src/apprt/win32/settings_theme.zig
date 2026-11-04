//! The Settings window's theme picker plumbing (T2586): where the themes
//! come from, and the two native popups the Theme section opens. The pure
//! rules (light/dark split, clash, seeding, mismatch) are
//! `theme_catalog.zig`; the section's painting is `SettingsWindow`.
//!
//! Mac draws the picker as a grid of preview tiles with a filter field and
//! light/dark tabs (`ThemeSection`); this window lists the same themes, in
//! the same two kinds, as native menus - a light & dark slot lists ONLY its
//! kind, exactly as Mac's tabs do, so the slots still cannot be mixed. The
//! tile grid is T2682.
const std = @import("std");
const Allocator = std.mem.Allocator;

const theme_locations = @import("../../config/theme.zig");
const theme_catalog = @import("theme_catalog.zig");
const w32 = @import("win32.zig");

/// Read the bundled themes, then the user's (which win a name clash).
pub fn loadCatalog(gpa: Allocator) Allocator.Error!theme_catalog.Catalog {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var sources: std.ArrayListUnmanaged(theme_catalog.Source) = .empty;
    // Low priority first: `config/theme.zig` lists them user-first.
    if (try theme_locations.Location.resources.dir(a)) |d| try sources.append(a, .{ .dir = d, .is_user = false });
    if (try theme_locations.Location.user.dir(a)) |d| try sources.append(a, .{ .dir = d, .is_user = true });
    return theme_catalog.load(gpa, sources.items);
}

/// "Use": Light & dark themes / One theme. Returns the pick (true = light &
/// dark), or null when the menu was dismissed.
pub fn modeMenu(gpa: Allocator, hwnd: w32.HWND, screen: w32.POINT, follows: bool) ?bool {
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);
    appendItem(gpa, menu, 1, "Light & dark themes", follows) catch return null;
    appendItem(gpa, menu, 2, "One theme", !follows) catch return null;
    const cmd = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, screen.x, screen.y, hwnd, null);
    if (cmd <= 0) return null;
    return cmd == 1;
}

/// What a theme menu lists: one kind (a light & dark slot), or both kinds
/// as two submenus (one theme - Mac's tabs are then just a filter).
pub const Kinds = enum { light, dark, both };

/// The theme menu. Returns the picked theme's index in `cat.themes`.
pub fn themeMenu(gpa: Allocator, hwnd: w32.HWND, screen: w32.POINT, cat: *const theme_catalog.Catalog, kinds: Kinds, current: []const u8) ?usize {
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);
    switch (kinds) {
        .light => fill(gpa, menu, cat, true, current) catch return null,
        .dark => fill(gpa, menu, cat, false, current) catch return null,
        .both => {
            // DestroyMenu on the parent destroys attached submenus.
            inline for (.{ .{ true, "Light themes" }, .{ false, "Dark themes" } }) |kind| {
                const sub = w32.CreatePopupMenu() orelse return null;
                fill(gpa, sub, cat, kind[0], current) catch {
                    _ = w32.DestroyMenu(sub);
                    return null;
                };
                const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, kind[1]) catch return null;
                defer gpa.free(wide);
                _ = w32.AppendMenuW(menu, w32.MF_STRING | w32.MF_POPUP, @intFromPtr(sub), wide.ptr);
            }
        },
    }
    const cmd = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, screen.x, screen.y, hwnd, null);
    if (cmd <= 0) return null;
    const idx: usize = @intCast(cmd - 1);
    return if (idx < cat.themes.len) idx else null;
}

fn fill(gpa: Allocator, menu: w32.HMENU, cat: *const theme_catalog.Catalog, light: bool, current: []const u8) !void {
    for (cat.themes, 0..) |*t, i| {
        if (t.isLight() != light) continue;
        var buf: [300]u8 = undefined;
        // Mac's tile tooltip: "(your theme)" marks a user theme.
        const label = if (t.is_user) std.fmt.bufPrint(&buf, "{s} (your theme)", .{t.name}) catch t.name else t.name;
        try appendItem(gpa, menu, i + 1, label, std.mem.eql(u8, t.name, current));
    }
}

fn appendItem(gpa: Allocator, menu: w32.HMENU, id: usize, label: []const u8, checked: bool) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, label);
    defer gpa.free(wide);
    _ = w32.AppendMenuW(menu, w32.MF_STRING | (if (checked) w32.MF_CHECKED else 0), id, wide.ptr);
}
