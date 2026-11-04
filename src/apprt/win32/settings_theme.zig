//! Where the Settings window's themes come from (T2586). The pure rules
//! (light/dark split, clash, seeding, mismatch) are `theme_catalog.zig`; the
//! tile grid's tab / filter / order rules are `settings_theme_grid.zig`
//! (T2682); the section's painting is `SettingsWindow`.
//!
//! T2586 first listed the themes as native popup menus; T2682 replaced them
//! with Mac's preview tiles, light/dark tabs and filter field, so all that
//! is left here is reading the catalog.
const std = @import("std");
const Allocator = std.mem.Allocator;

const theme_locations = @import("../../config/theme.zig");
const theme_catalog = @import("theme_catalog.zig");

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
