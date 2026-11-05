//! Carries the keys ConPTY cannot express past it (T2693).
//!
//! ConPTY asks the terminal for Win32 Input Mode (DEC 9001), so every key
//! leaves Ghoztty as a key record (`CSI Vk;Sc;Uc;Kd;Cs;Rc _`) and conhost
//! turns that record back into bytes for the program. A program that reads
//! VT input and has asked for the kitty keyboard protocol (`CSI > 1 u`) or
//! xterm modifyOtherKeys 2 (`CSI > 4 ; 2 m`) never gets what it asked for:
//! those requests pass straight through conhost to Ghoztty, which records
//! them, but conhost itself still flattens a modified Enter into the same
//! byte as the plain key. Measured on 2026-11-05 with a raw-mode reader
//! that sets up its keys the way Claude Code does under TERM_PROGRAM=ghostty:
//! Ctrl+Enter arrived as `0a` (indistinguishable from Ctrl+J), Shift+Enter as
//! `0d` (indistinguishable from Enter). On macOS the same reader gets
//! `CSI 13;5u` and `CSI 13;2u`, so Claude Code's Ctrl+Enter (send now) and
//! Shift+Enter (new line) work there and did nothing here.
//!
//! Writing the kitty sequence into ConPTY raw does not help - conhost's
//! input parser drops a `CSI ... u` it does not know (measured the same
//! day). What does pass through untouched is a CHARACTER record, so the
//! surface sends each byte of the encoded sequence as a Win32 Input Mode
//! char event and the program reads exactly the bytes a macOS Ghoztty
//! would have written.
//!
//! The bridge is deliberately narrow: only Enter, keypad Enter, Tab,
//! Backspace and Escape, only with Ctrl, Alt or Shift held, and only while
//! the program has asked for kitty flags or modifyOtherKeys 2. Those are the
//! keys whose modified forms a key record cannot carry to a VT reader.
//! Everything else - text, dead keys, Ctrl+letter, Ctrl+C - stays a key
//! record, so console-API programs, interrupts and IME input are untouched.
//! This module is the pure half (the decision and the bytes); the surface
//! owns the delivery.

const std = @import("std");
const input = @import("../../input.zig");

const Options = input.key_encode.Options;

/// Whether a key event must bypass the key record and be sent as the
/// encoder's bytes instead.
pub fn applies(opts: Options, key: input.Key, mods: input.Mods) bool {
    if (opts.kitty_flags.int() == 0 and !opts.modify_other_keys_state_2) return false;
    switch (key) {
        .enter, .numpad_enter, .tab, .backspace, .escape => {},
        else => return false,
    }
    return mods.ctrl or mods.alt or mods.shift;
}

/// The bytes the program asked for, or null when the key record should be
/// sent as before. An empty slice is a real answer: the program's flags say
/// this event (a release without report_events, say) produces nothing.
pub fn encode(
    buf: []u8,
    opts: Options,
    action: input.Action,
    key: input.Key,
    mods: input.Mods,
) ?[]const u8 {
    if (!applies(opts, key, mods)) return null;
    var writer: std.Io.Writer = .fixed(buf);
    input.key_encode.encode(&writer, .{
        .action = action,
        .key = key,
        .mods = mods,
        .utf8 = "",
    }, opts) catch return null;
    return writer.buffered();
}

const testing = std.testing;

const kitty1: Options = .{ .kitty_flags = .{ .disambiguate = true } };

fn expectBytes(want: ?[]const u8, opts: Options, action: input.Action, key: input.Key, mods: input.Mods) !void {
    var buf: [64]u8 = undefined;
    const got = encode(&buf, opts, action, key, mods);
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "T2693: kitty flags carry modified enter as CSI u, the bytes Mac sends" {
    try expectBytes("\x1b[13;5u", kitty1, .press, .enter, .{ .ctrl = true });
    try expectBytes("\x1b[13;2u", kitty1, .press, .enter, .{ .shift = true });
    try expectBytes("\x1b[13;3u", kitty1, .press, .enter, .{ .alt = true });
    try expectBytes("\x1b[9;5u", kitty1, .press, .tab, .{ .ctrl = true });
    try expectBytes("\x1b[127;5u", kitty1, .press, .backspace, .{ .ctrl = true });
}

test "T2693: modifyOtherKeys 2 alone carries ctrl+enter as its CSI 27 form" {
    const mok: Options = .{ .modify_other_keys_state_2 = true };
    try expectBytes("\x1b[27;5;13~", mok, .press, .enter, .{ .ctrl = true });
}

test "T2693: no request from the program means the key record, unchanged" {
    try expectBytes(null, .{}, .press, .enter, .{ .ctrl = true });
    try expectBytes(null, .{}, .press, .enter, .{ .shift = true });
}

test "T2693: plain keys and everything outside the five stay key records" {
    // Unmodified enter must keep its key record: console programs read it.
    try expectBytes(null, kitty1, .press, .enter, .{});
    try expectBytes(null, kitty1, .press, .escape, .{});
    // Ctrl+C stays a key record so it still raises the console interrupt.
    try expectBytes(null, kitty1, .press, .key_c, .{ .ctrl = true });
    try expectBytes(null, kitty1, .press, .key_a, .{ .ctrl = true });
    try expectBytes(null, kitty1, .press, .arrow_up, .{ .ctrl = true });
}

test "T2693: a release without report_events is answered with no bytes" {
    try expectBytes("", kitty1, .release, .enter, .{ .ctrl = true });
}

test "T2693: negative control - the decision really reads the flags" {
    // If `applies` ignored the program's request, this would bridge.
    try testing.expect(!applies(.{}, .enter, .{ .ctrl = true }));
    try testing.expect(applies(kitty1, .enter, .{ .ctrl = true }));
}
