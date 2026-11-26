//! The font families DirectWrite knows, for the Settings window's Font row
//! (T3766) - the Windows half of Mac `FontControl.monospacedFamilies`, which
//! lists `NSFontManager`'s fixed-pitch families. Linux's is
//! `src/apprt/gtk/font_families.zig` (fontconfig).
//!
//! `mono` is what the picker offers: every family of the system font
//! collection with a face DirectWrite calls monospaced
//! (`IDWriteFont1::IsMonospacedFont`), cleaned up by the shared
//! `settings_controls.fontFamilies`. `all` is every installed family, so a
//! configured primary that IS installed but proportional is not called
//! missing.
//!
//! A family's name is its en-us name (the name the font is matched by),
//! else its first. dwrite.dll is loaded at run time, as `child_comp.zig`
//! loads dcomp: a box without it lists nothing, and the row is then just
//! Default plus whatever the config names.
const std = @import("std");
const Allocator = std.mem.Allocator;
const controls = @import("settings_controls.zig");

const GUID = std.os.windows.GUID;
const HRESULT = std.os.windows.HRESULT;
const BOOL = i32;
const Obj = *anyopaque;

pub const Families = struct {
    /// The picker's families: monospaced, sorted, unique.
    mono: []const []const u8 = &.{},
    /// Every installed family (sorted, unique).
    all: []const []const u8 = &.{},
};

extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;

const DWriteCreateFactoryFn = *const fn (u32, *const GUID, *?Obj) callconv(.winapi) HRESULT;

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}
const IID_IDWriteFactory = guid("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");
const IID_IDWriteFont1 = guid("acd16696-8c14-4f5d-877e-fe3fc1d32738");

// vtable slots (IUnknown is 0-2).
const slot_query = 0;
const slot_release = 2;
const slot_factory_get_system_font_collection = 3;
const slot_collection_get_family_count = 3;
const slot_collection_get_family = 4;
const slot_list_get_font_count = 4; // IDWriteFontList, IDWriteFontFamily's base
const slot_list_get_font = 5;
const slot_family_get_family_names = 6;
const slot_font1_is_monospaced = 17;
const slot_strings_get_count = 3;
const slot_strings_find_locale = 4;
const slot_strings_get_length = 7;
const slot_strings_get_string = 8;

fn slot(comptime F: type, obj: Obj, index: usize) F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtbl.*[index]);
}

fn release(obj: Obj) void {
    _ = slot(*const fn (Obj) callconv(.winapi) u32, obj, slot_release)(obj);
}

var factory: ?Obj = null;
var factory_tried = false;

/// The shared DirectWrite factory, made once per process (null when
/// dwrite.dll is missing).
fn getFactory() ?Obj {
    if (factory_tried) return factory;
    factory_tried = true;
    const dll = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dwrite.dll")) orelse return null;
    const proc = GetProcAddress(dll, "DWriteCreateFactory") orelse return null;
    const create: DWriteCreateFactoryFn = @ptrCast(proc);
    var out: ?Obj = null;
    // DWRITE_FACTORY_TYPE_SHARED.
    if (create(0, &IID_IDWriteFactory, &out) < 0) return null;
    factory = out;
    return factory;
}

/// Ask DirectWrite. Every string is allocated with `arena`.
pub fn load(arena: Allocator) Allocator.Error!Families {
    const f = getFactory() orelse return .{};
    var coll_opt: ?Obj = null;
    // checkForUpdates = TRUE, so a font installed since the last ask is in.
    if (slot(*const fn (Obj, *?Obj, BOOL) callconv(.winapi) HRESULT, f, slot_factory_get_system_font_collection)(f, &coll_opt, 1) < 0) return .{};
    const coll = coll_opt orelse return .{};
    defer release(coll);

    var mono: std.ArrayListUnmanaged([]const u8) = .empty;
    var all: std.ArrayListUnmanaged([]const u8) = .empty;
    const count = slot(*const fn (Obj) callconv(.winapi) u32, coll, slot_collection_get_family_count)(coll);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var fam_opt: ?Obj = null;
        if (slot(*const fn (Obj, u32, *?Obj) callconv(.winapi) HRESULT, coll, slot_collection_get_family)(coll, i, &fam_opt) < 0) continue;
        const fam = fam_opt orelse continue;
        defer release(fam);
        const name = (try familyName(arena, fam)) orelse continue;
        try all.append(arena, name);
        if (isMonospacedFamily(fam)) try mono.append(arena, name);
    }
    return .{
        .mono = try controls.fontFamilies(arena, mono.items),
        .all = try controls.fontFamilies(arena, all.items),
    };
}

/// Whether any face of `fam` reports itself monospaced.
fn isMonospacedFamily(fam: Obj) bool {
    const n = slot(*const fn (Obj) callconv(.winapi) u32, fam, slot_list_get_font_count)(fam);
    var j: u32 = 0;
    while (j < n) : (j += 1) {
        var font_opt: ?Obj = null;
        if (slot(*const fn (Obj, u32, *?Obj) callconv(.winapi) HRESULT, fam, slot_list_get_font)(fam, j, &font_opt) < 0) continue;
        const font = font_opt orelse continue;
        defer release(font);
        var f1_opt: ?Obj = null;
        // IDWriteFont1 is Windows 8+; without it nothing is called monospaced.
        if (slot(*const fn (Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT, font, slot_query)(font, &IID_IDWriteFont1, &f1_opt) < 0) return false;
        const f1 = f1_opt orelse return false;
        defer release(f1);
        if (slot(*const fn (Obj) callconv(.winapi) BOOL, f1, slot_font1_is_monospaced)(f1) != 0) return true;
    }
    return false;
}

/// The family's en-us name, else its first; UTF-8 in `arena`.
fn familyName(arena: Allocator, fam: Obj) Allocator.Error!?[]const u8 {
    var names_opt: ?Obj = null;
    if (slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, fam, slot_family_get_family_names)(fam, &names_opt) < 0) return null;
    const names = names_opt orelse return null;
    defer release(names);
    if (slot(*const fn (Obj) callconv(.winapi) u32, names, slot_strings_get_count)(names) == 0) return null;
    var index: u32 = 0;
    var exists: BOOL = 0;
    const en = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
    if (slot(*const fn (Obj, [*:0]const u16, *u32, *BOOL) callconv(.winapi) HRESULT, names, slot_strings_find_locale)(names, en, &index, &exists) < 0 or exists == 0) index = 0;
    var len: u32 = 0;
    if (slot(*const fn (Obj, u32, *u32) callconv(.winapi) HRESULT, names, slot_strings_get_length)(names, index, &len) < 0) return null;
    if (len == 0 or len > 512) return null;
    var wbuf: [513]u16 = undefined;
    if (slot(*const fn (Obj, u32, [*]u16, u32) callconv(.winapi) HRESULT, names, slot_strings_get_string)(names, index, &wbuf, len + 1) < 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(arena, wbuf[0..len]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

test "font_families: DirectWrite lists Consolas as monospaced and Segoe UI as not" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const fams = try load(arena_state.allocator());
    // Both ship with every Windows since Vista.
    try std.testing.expect(controls.hasFamily(fams.mono, "Consolas"));
    try std.testing.expect(!controls.hasFamily(fams.mono, "Segoe UI"));
    try std.testing.expect(controls.hasFamily(fams.all, "Segoe UI"));
    try std.testing.expect(fams.all.len >= fams.mono.len);
}
