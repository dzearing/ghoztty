//! The font families fontconfig knows, for the Settings window's Font row
//! (T3765) - the Linux half of Mac `FontControl.monospacedFamilies`, which
//! lists `NSFontManager`'s fixed-pitch families.
//!
//! `mono` is what the picker offers: every family with a face fontconfig
//! calls monospaced (`FC_SPACING` mono or charcell - the spacing Ghostty's
//! own discovery asks for), cleaned up by the shared `fontFamilies`.
//! `all` is every installed family, so a configured primary that IS
//! installed but proportional is not called missing.
//!
//! A build whose font backend is not fontconfig lists nothing: the row is
//! then just Default plus whatever the config names.
const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../../font/main.zig");
const controls = @import("../win32/settings_controls.zig");

const has_fc = font.options.backend.hasFontconfig();
const fontconfig = if (has_fc) @import("fontconfig") else struct {};

pub const Families = struct {
    /// The picker's families: monospaced, sorted, unique.
    mono: []const []const u8,
    /// Every installed family (sorted, unique).
    all: []const []const u8,
};

/// Ask fontconfig. Every string is allocated with `arena`.
pub fn load(arena: Allocator) Allocator.Error!Families {
    if (comptime !has_fc) return .{ .mono = &.{}, .all = &.{} };
    // Safe to call repeatedly; discovery does the same.
    _ = fontconfig.init();
    const cfg = fontconfig.initLoadConfigAndFonts();
    defer cfg.destroy();

    const pat = fontconfig.Pattern.create();
    defer pat.destroy();
    const os = fontconfig.ObjectSet.create();
    defer os.destroy();
    _ = os.add(.family);
    _ = os.add(.spacing);
    const set = cfg.fontList(pat, os);
    defer set.destroy();

    var mono: std.ArrayListUnmanaged([]const u8) = .empty;
    var all: std.ArrayListUnmanaged([]const u8) = .empty;
    for (set.fonts()) |f| {
        // The first family name is the face's own; later ones are
        // localized aliases.
        const fam = switch (f.get(.family, 0) catch continue) {
            .string => |s| s,
            else => continue,
        };
        const name = try arena.dupe(u8, fam);
        try all.append(arena, name);
        const spacing: i32 = switch (f.get(.spacing, 0) catch continue) {
            .integer => |i| i,
            else => continue,
        };
        if (spacing == @intFromEnum(fontconfig.Spacing.mono) or
            spacing == @intFromEnum(fontconfig.Spacing.charcell)) try mono.append(arena, name);
    }
    return .{
        .mono = try controls.fontFamilies(arena, mono.items),
        .all = try controls.fontFamilies(arena, all.items),
    };
}
