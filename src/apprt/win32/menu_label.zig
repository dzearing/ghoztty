//! Menu item text: the base title plus a tab and the accelerator, when the
//! live keybind set has a trigger for the item's action.
//!
//! This is the Windows convention and the app's only self-teaching surface
//! for chords — T129: the pane banner's ctrl+shift+b differs from the Mac
//! cmd+r and was named nowhere, so users concluded the feature was broken.
//! Reading the trigger from config means a rebind relabels the menu, and an
//! unbound action simply shows no hint.
//!
//! It lives here rather than in `Surface.zig` because there are now two menu
//! surfaces over the same commands — the right-click context menu (T102) and
//! the menu system opened from the tab strip (T143/T190) — and a second
//! hand-written formatter is the same drift `commands.zig` exists to stop.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.

const std = @import("std");
const input = @import("../../input.zig");

/// Longest label a menu row can carry: base title + '\t' + accelerator + NUL.
/// A row that would not fit falls back to its bare title rather than being
/// truncated mid-chord.
pub const BUF_LEN = 96;

pub const Buf = [BUF_LEN]u16;

/// Format a keybinding trigger as a human-readable string (e.g.
/// "Ctrl+Shift+T"). Returns the number of bytes written to `buf`.
///
/// Modifier order is Windows' own (Win, Ctrl, Alt, Shift), which is what the
/// system's menus and every shipped Windows app print.
pub fn formatTrigger(trigger: input.Binding.Trigger, buf: []u8) usize {
    var pos: usize = 0;

    inline for (.{
        .{ trigger.mods.super, "Win+" },
        .{ trigger.mods.ctrl, "Ctrl+" },
        .{ trigger.mods.alt, "Alt+" },
        .{ trigger.mods.shift, "Shift+" },
    }) |pair| {
        if (pair[0] and pos + pair[1].len <= buf.len) {
            @memcpy(buf[pos..][0..pair[1].len], pair[1]);
            pos += pair[1].len;
        }
    }

    switch (trigger.key) {
        .unicode => |cp| {
            if (pos < buf.len) {
                // Upper-case letters for display, like every Windows menu.
                if (cp >= 'a' and cp <= 'z') {
                    buf[pos] = @intCast(cp - 32);
                    pos += 1;
                } else if (cp >= ' ' and cp <= '~') {
                    buf[pos] = @intCast(cp);
                    pos += 1;
                }
            }
        },
        .physical => |k| {
            const name = keyName(k);
            if (name.len > 0 and pos + name.len <= buf.len) {
                @memcpy(buf[pos..][0..name.len], name);
                pos += name.len;
            }
        },
        .catch_all => {},
    }

    return pos;
}

/// Map physical key enum to display name.
pub fn keyName(k: input.Key) []const u8 {
    return switch (k) {
        .key_a => "A",
        .key_b => "B",
        .key_c => "C",
        .key_d => "D",
        .key_e => "E",
        .key_f => "F",
        .key_g => "G",
        .key_h => "H",
        .key_i => "I",
        .key_j => "J",
        .key_k => "K",
        .key_l => "L",
        .key_m => "M",
        .key_n => "N",
        .key_o => "O",
        .key_p => "P",
        .key_q => "Q",
        .key_r => "R",
        .key_s => "S",
        .key_t => "T",
        .key_u => "U",
        .key_v => "V",
        .key_w => "W",
        .key_x => "X",
        .key_y => "Y",
        .key_z => "Z",
        .digit_0 => "0",
        .digit_1 => "1",
        .digit_2 => "2",
        .digit_3 => "3",
        .digit_4 => "4",
        .digit_5 => "5",
        .digit_6 => "6",
        .digit_7 => "7",
        .digit_8 => "8",
        .digit_9 => "9",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        .space => "Space",
        .enter => "Enter",
        .tab => "Tab",
        .backspace => "Backspace",
        .escape => "Escape",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .home => "Home",
        .end => "End",
        .insert => "Insert",
        .delete => "Delete",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .semicolon => ";",
        .quote => "'",
        .bracket_left => "[",
        .bracket_right => "]",
        .backslash => "\\",
        .minus => "-",
        .equal => "=",
        .backquote => "`",
        else => "",
    };
}

/// Chords to advertise for an action ahead of the binding set's reverse map,
/// best first (T1354).
///
/// The reverse map deliberately skips performable bindings, and every copy
/// and paste chord a Windows user actually presses is performable (ctrl+c
/// copies only with a selection, ctrl+v pastes only with text on the
/// clipboard). What the map is left holding is the generic non-darwin
/// ctrl+insert for copy, and nothing at all for paste — shift+insert's later
/// rebind to paste_from_selection evicted it. So the Edit menu taught
/// Ctrl+Insert and gave Paste no hint, where the Mac menu shows Cmd+C/Cmd+V.
///
/// A candidate is advertised only while the live set still binds it to the
/// same action, so a user who rebinds ctrl+c falls through to the next one
/// and finally to the reverse map. Kept here rather than in `Binding.Set` so
/// GTK and the C API resolve exactly what they did before.
const preferred = [_]struct {
    action: input.Binding.Action,
    triggers: []const input.Binding.Trigger,
}{
    .{
        .action = .{ .copy_to_clipboard = .mixed },
        .triggers = &.{
            .{ .mods = .{ .ctrl = true }, .key = .{ .unicode = 'c' } },
            .{ .mods = .{ .ctrl = true, .shift = true }, .key = .{ .unicode = 'c' } },
            .{ .mods = .{ .ctrl = true }, .key = .{ .physical = .insert } },
        },
    },
    .{
        .action = .paste_from_clipboard,
        .triggers = &.{
            .{ .mods = .{ .ctrl = true }, .key = .{ .unicode = 'v' } },
            .{ .mods = .{ .ctrl = true, .shift = true }, .key = .{ .unicode = 'v' } },
            .{ .mods = .{ .shift = true }, .key = .{ .physical = .insert } },
        },
    },
};

/// The chord a menu row should advertise for `action`: the first preferred
/// candidate the live set still binds to it, else the reverse map's trigger.
/// Every win32 surface that labels a command reads it through here, so the
/// menu bar, the context menu and the palette cannot disagree.
pub fn accelTrigger(set: *const input.Binding.Set, action: input.Binding.Action) ?input.Binding.Trigger {
    const h = action.hash();
    for (preferred) |p| {
        if (p.action.hash() != h) continue;
        for (p.triggers) |t| {
            const entry = set.get(t) orelse continue;
            switch (entry.value_ptr.*) {
                .leaf => |leaf| if (leaf.action.hash() == h) return t,
                .leader, .leaf_chained => {},
            }
        }
        break;
    }
    return set.getTrigger(action);
}

/// `title`, or `title\t<accel>` written into `buf` when `trigger` is
/// non-null and formats to something. Returns a pointer suitable for
/// `AppendMenuW` — either into `buf` or `title` itself, so the caller must
/// keep `buf` alive until the string is copied (AppendMenuW copies it).
pub fn withAccel(
    title: [:0]const u16,
    trigger: ?input.Binding.Trigger,
    buf: *Buf,
) [*:0]const u16 {
    const t = trigger orelse return title.ptr;

    var accel: [64]u8 = undefined;
    const accel_len = formatTrigger(t, &accel);
    if (accel_len == 0) return title.ptr;

    // title + '\t' + accel + NUL; fall back to the bare title if it can't
    // fit (accel is ASCII, so one u16 per byte).
    if (title.len + 1 + accel_len + 1 > buf.len) return title.ptr;
    @memcpy(buf[0..title.len], title[0..title.len]);
    var pos = title.len;
    buf[pos] = '\t';
    pos += 1;
    pos += std.unicode.utf8ToUtf16Le(buf[pos..], accel[0..accel_len]) catch
        return title.ptr;
    buf[pos] = 0;
    return @ptrCast(buf);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn u16lit(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn fmt(trigger: input.Binding.Trigger, buf: []u8) []const u8 {
    return buf[0..formatTrigger(trigger, buf)];
}

test "modifiers print in Windows order" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+B", fmt(.{
        .mods = .{ .ctrl = true, .shift = true },
        .key = .{ .unicode = 'b' },
    }, &buf));
    try testing.expectEqualStrings("Win+Ctrl+Alt+Shift+K", fmt(.{
        .mods = .{ .super = true, .ctrl = true, .alt = true, .shift = true },
        .key = .{ .unicode = 'k' },
    }, &buf));
}

test "physical keys print their name, unbound-shaped triggers print nothing" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+F10", fmt(.{
        .mods = .{ .ctrl = true },
        .key = .{ .physical = .f10 },
    }, &buf));
    // catch_all has no printable key, so the accelerator is modifiers only —
    // `withAccel` still labels it, but a key we have no name for yields "".
    try testing.expectEqualStrings("", fmt(.{
        .mods = .{},
        .key = .{ .physical = .numpad_0 },
    }, &buf));
}

test "withAccel appends the chord after a tab" {
    var buf: Buf = undefined;
    const out = withAccel(u16lit("Set Pane Banner…"), .{
        .mods = .{ .ctrl = true, .shift = true },
        .key = .{ .unicode = 'b' },
    }, &buf);
    const len = std.mem.len(out);
    try testing.expectEqualSlices(
        u16,
        u16lit("Set Pane Banner…\tCtrl+Shift+B"),
        out[0..len],
    );
}

test "an unbound command keeps its bare title" {
    var buf: Buf = undefined;
    const title = u16lit("&About Ghoztty");
    // No trigger at all...
    try testing.expectEqual(title.ptr, withAccel(title, null, &buf));
    // ...and a trigger that formats to nothing (no printable key) must not
    // leave a dangling tab on the row.
    try testing.expectEqual(title.ptr, withAccel(title, .{
        .mods = .{},
        .key = .{ .physical = .numpad_0 },
    }, &buf));
}

/// Triggers have no `eql`; their hash is what the binding set keys on.
fn same(a: ?input.Binding.Trigger, b: input.Binding.Trigger) bool {
    return if (a) |t| t.hash() == b.hash() else false;
}

const ctrl_c: input.Binding.Trigger = .{ .mods = .{ .ctrl = true }, .key = .{ .unicode = 'c' } };
const ctrl_v: input.Binding.Trigger = .{ .mods = .{ .ctrl = true }, .key = .{ .unicode = 'v' } };
const ctrl_ins: input.Binding.Trigger = .{ .mods = .{ .ctrl = true }, .key = .{ .physical = .insert } };
const shift_ins: input.Binding.Trigger = .{ .mods = .{ .shift = true }, .key = .{ .physical = .insert } };

test "copy and paste advertise ctrl+c and ctrl+v over the reverse map" {
    const alloc = testing.allocator;
    var set: input.Binding.Set = .{};
    defer set.deinit(alloc);

    // The default config's shape: plain put()s for the insert chords, then
    // the performable ctrl chords the reverse map never records.
    try set.put(alloc, ctrl_ins, .{ .copy_to_clipboard = .mixed });
    try set.put(alloc, shift_ins, .paste_from_clipboard);
    try set.putFlags(alloc, ctrl_c, .{ .copy_to_clipboard = .mixed }, .{ .performable = true });
    try set.putFlags(alloc, ctrl_v, .paste_from_clipboard, .{ .performable = true });

    try testing.expect(same(set.getTrigger(.{ .copy_to_clipboard = .mixed }), ctrl_ins));
    try testing.expect(same(accelTrigger(&set, .{ .copy_to_clipboard = .mixed }), ctrl_c));
    try testing.expect(same(accelTrigger(&set, .paste_from_clipboard), ctrl_v));
}

test "a rebound preferred chord falls through to the reverse map" {
    const alloc = testing.allocator;
    var set: input.Binding.Set = .{};
    defer set.deinit(alloc);

    try set.put(alloc, ctrl_ins, .{ .copy_to_clipboard = .mixed });
    // ctrl+c now does something else, so the menu must not promise it copies.
    try set.put(alloc, ctrl_c, .{ .text = "x" });

    try testing.expect(same(accelTrigger(&set, .{ .copy_to_clipboard = .mixed }), ctrl_ins));
    // A different copy format is a different action and is not overridden.
    try testing.expectEqual(@as(?input.Binding.Trigger, null), accelTrigger(&set, .{ .copy_to_clipboard = .plain }));
}

test "actions with no preference read the reverse map unchanged" {
    const alloc = testing.allocator;
    var set: input.Binding.Set = .{};
    defer set.deinit(alloc);

    const t: input.Binding.Trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key = .{ .unicode = 'b' } };
    try set.put(alloc, t, .{ .new_tab = {} });
    try testing.expect(same(accelTrigger(&set, .{ .new_tab = {} }), t));
    try testing.expectEqual(@as(?input.Binding.Trigger, null), accelTrigger(&set, .{ .close_tab = .this }));
}

test "the default Windows config labels Copy Ctrl+C and Paste Ctrl+V" {
    const builtin = @import("builtin");
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const Config = @import("../../config.zig").Config;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const set = &cfg.keybind.set;

    // The defect as shipped: the reverse map advertises the OS/2-era chord
    // for Copy, and has lost Paste to the selection-clipboard rebind.
    try testing.expect(same(set.getTrigger(.{ .copy_to_clipboard = .mixed }), ctrl_ins));
    try testing.expect(!same(set.getTrigger(.paste_from_clipboard), ctrl_v));

    try testing.expect(same(accelTrigger(set, .{ .copy_to_clipboard = .mixed }), ctrl_c));
    try testing.expect(same(accelTrigger(set, .paste_from_clipboard), ctrl_v));
}

test "an over-long title falls back to itself rather than truncating" {
    var buf: Buf = undefined;
    const long = u16lit("A" ** (BUF_LEN - 4));
    const out = withAccel(long, .{
        .mods = .{ .ctrl = true, .shift = true },
        .key = .{ .unicode = 'b' },
    }, &buf);
    try testing.expectEqual(long.ptr, out);
}
