//! Viewer-pane accelerator forwarding, the pure half (T394).
//!
//! A focused viewer pane's keyboard lives inside WebView2's Chromium child
//! HWNDs, which never reach our WndProc — so the app keybind table (palette,
//! new tab, close) is dead there unless the controller's
//! `AcceleratorKeyPressed` event hands the chord back to us. This module is
//! the part of that path that needs no OS: mapping the event's Win32
//! virtual-key + modifier state to the `input.KeyEvent` the app keybind set
//! is consulted with, and naming WHICH bound actions a viewer pane may
//! perform at all.
//!
//! No OS imports, so the unit tests run in every app-runtime lane. The
//! virtual-key values are therefore literals; `Surface.zig` (win32 lane)
//! holds the drift guard that compares this table against its own
//! `mapVirtualKey` over the whole 8-bit VK space, so a transcription error
//! here fails the win32 lane rather than shipping.

const std = @import("std");
const input = @import("../../input.zig");

/// Map a Win32 virtual-key code to a Ghostty `input.Key`. The same table as
/// `Surface.mapVirtualKey`, with the `w32.VK_*` names spelled as their
/// values (this file cannot import an OS surface).
pub fn keyFromVk(vk: u16, extended: bool) input.Key {
    return switch (vk) {
        // Letter keys (A-Z: 0x41-0x5A)
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,

        // Number keys (0-9: 0x30-0x39)
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,

        // Function keys (VK_F1..VK_F24: 0x70-0x87)
        0x70 => .f1,
        0x71 => .f2,
        0x72 => .f3,
        0x73 => .f4,
        0x74 => .f5,
        0x75 => .f6,
        0x76 => .f7,
        0x77 => .f8,
        0x78 => .f9,
        0x79 => .f10,
        0x7A => .f11,
        0x7B => .f12,
        0x7C => .f13,
        0x7D => .f14,
        0x7E => .f15,
        0x7F => .f16,
        0x80 => .f17,
        0x81 => .f18,
        0x82 => .f19,
        0x83 => .f20,
        0x84 => .f21,
        0x85 => .f22,
        0x86 => .f23,
        0x87 => .f24,

        // Navigation / editing keys
        0x0D => if (extended) .numpad_enter else .enter, // VK_RETURN
        0x08 => .backspace, // VK_BACK
        0x09 => .tab, // VK_TAB
        0x1B => .escape, // VK_ESCAPE
        0x20 => .space, // VK_SPACE
        0x21 => .page_up, // VK_PRIOR
        0x22 => .page_down, // VK_NEXT
        0x23 => .end, // VK_END
        0x24 => .home, // VK_HOME
        0x25 => .arrow_left, // VK_LEFT
        0x26 => .arrow_up, // VK_UP
        0x27 => .arrow_right, // VK_RIGHT
        0x28 => .arrow_down, // VK_DOWN
        0x2D => .insert, // VK_INSERT
        0x2E => .delete, // VK_DELETE

        // Modifier keys
        0xA0 => .shift_left, // VK_LSHIFT
        0xA1 => .shift_right, // VK_RSHIFT
        0xA2 => .control_left, // VK_LCONTROL
        0xA3 => .control_right, // VK_RCONTROL
        0xA4 => .alt_left, // VK_LMENU
        0xA5 => .alt_right, // VK_RMENU
        0x5B => .meta_left, // VK_LWIN
        0x5C => .meta_right, // VK_RWIN
        0x10 => if (extended) .shift_right else .shift_left, // VK_SHIFT
        0x11 => if (extended) .control_right else .control_left, // VK_CONTROL
        0x12 => if (extended) .alt_right else .alt_left, // VK_MENU

        // Lock keys
        0x14 => .caps_lock, // VK_CAPITAL
        0x90 => .num_lock, // VK_NUMLOCK
        0x91 => .scroll_lock, // VK_SCROLL

        // OEM keys (US keyboard layout)
        0xBA => .semicolon, // VK_OEM_1
        0xBB => .equal, // VK_OEM_PLUS
        0xBC => .comma, // VK_OEM_COMMA
        0xBD => .minus, // VK_OEM_MINUS
        0xBE => .period, // VK_OEM_PERIOD
        0xBF => .slash, // VK_OEM_2
        0xC0 => .backquote, // VK_OEM_3
        0xDB => .bracket_left, // VK_OEM_4
        0xDC => .backslash, // VK_OEM_5
        0xDD => .bracket_right, // VK_OEM_6
        0xDE => .quote, // VK_OEM_7

        // Numpad keys (0x60-0x6F)
        0x60 => .numpad_0,
        0x61 => .numpad_1,
        0x62 => .numpad_2,
        0x63 => .numpad_3,
        0x64 => .numpad_4,
        0x65 => .numpad_5,
        0x66 => .numpad_6,
        0x67 => .numpad_7,
        0x68 => .numpad_8,
        0x69 => .numpad_9,
        0x6A => .numpad_multiply, // VK_MULTIPLY
        0x6B => .numpad_add, // VK_ADD
        0x6C => .numpad_separator, // VK_SEPARATOR
        0x6D => .numpad_subtract, // VK_SUBTRACT
        0x6E => .numpad_decimal, // VK_DECIMAL
        0x6F => .numpad_divide, // VK_DIVIDE

        // Misc
        0x5D => .context_menu, // VK_APPS
        0x13 => .pause, // VK_PAUSE

        else => .unidentified,
    };
}

/// Build the `input.KeyEvent` the app keybind set is consulted with for an
/// accelerator chord, or null when the key can never name a binding here: a
/// bare modifier, or a key this table cannot identify (there is no ToUnicode
/// on this path, so an unidentified key has no codepoint to match either).
///
/// The event carries no UTF-8 (the accelerator event precedes translation),
/// so `Binding.Set.getEvent` matches on the physical key first and then on
/// the key's unshifted codepoint — which is exactly how the default
/// `ctrl+shift+p`-style bindings are stored (as unicode triggers).
pub fn keyEventFor(vk: u16, extended: bool, mods: input.Mods) ?input.KeyEvent {
    const key = keyFromVk(vk, extended);
    if (key == .unidentified) return null;
    if (key.modifier()) return null;
    return .{
        .action = .press,
        .key = key,
        .mods = mods,
        .consumed_mods = .{},
        .utf8 = "",
        .unshifted_codepoint = if (key.codepoint()) |cp| cp else 0,
    };
}

/// Where an app keybind chord from a focused viewer pane goes (T1803, Mac
/// `ViewerKeyFallback.Route`).
pub const Route = enum {
    /// Not ours: the page keeps the key exactly as it always did.
    pass,
    /// Performed on the VIEWER by `Window.performViewerBindingAction` — the
    /// Windows counterpart of Mac's menu items, the handlers that know a
    /// viewer can be the focused pane (split, close, stash and zoom act on
    /// the viewer itself from here).
    native,
    /// Performed through the core (`App.performBindingForNonTerminal`), never
    /// as terminal input: app actions with no surface, window actions through
    /// a terminal in the same window.
    core,
};

/// Decide where a bound chord from a focused viewer goes. Pure, so the
/// policy is testable without a pane, a window or a running app — Mac's
/// `ViewerKeyFallback.route`, with the menu replaced by our native dispatch.
///
/// The rule: **a chord the pane does not claim itself reaches Ghoztty's
/// bindings exactly as it would from a focused terminal, minus the bindings
/// that need a terminal.** What needs one is decided by the core,
/// exhaustively (`Binding.Action.requires`): `text:`/`csi:`, copy/paste, font
/// size, scrolling and search would otherwise be performed through some
/// OTHER terminal in the window — typed into a shell the user is not looking
/// at. Before T1803 this was a hand-kept allowlist of window commands, so a
/// custom binding, or any action nobody had remembered to list, silently did
/// nothing from a viewer.
///
/// - `has_host_surface`: the window has a terminal for the core to perform a
///   window-scoped action through. A window of nothing but viewers has none.
pub fn route(leaf: *const input.Binding.Set.GenericLeaf, has_host_surface: bool) Route {
    const actions = leaf.actionsSlice();
    if (actions.len == 0) return .pass;

    // Global and all-surface bindings are explicitly not about the focused
    // pane: the core performs them on every surface, as from a terminal.
    if (leaf.flags.global or leaf.flags.all) return .core;

    // The most demanding requirement across a chain decides it, the way the
    // core's `ghostty_config_key_binding` reports a chain to Mac.
    var requires: input.Binding.Action.Requires = .app;
    for (actions) |action| {
        const r = action.requires();
        if (@intFromEnum(r) > @intFromEnum(requires)) requires = r;
    }
    if (requires == .terminal) return .pass;

    // Our own dispatch first, as Mac prefers its menu: it acts on the viewer
    // the user is looking at. A chain has no single native handler.
    if (actions.len == 1 and native(actions[0])) return .native;

    return switch (requires) {
        .app => .core,
        .window => if (has_host_surface) .core else .pass,
        // A pane action performed through a terminal would act on THAT
        // terminal's pane, not the viewer the user is looking at.
        .pane, .terminal => .pass,
    };
}

/// Chords the page itself uses, which no binding takes from a focused viewer
/// (T1803). Mac gets this ordering for free — the page and a focused text
/// field claim a key before the fallback is asked — but WebView2's
/// accelerator event fires BEFORE the page sees the key, so the page's first
/// claim has to be spelled out: the editing chords (ctrl+C/V/X/A/Z/Y and
/// ctrl+shift+Z) and ctrl-arrow/Home/End/Backspace/Delete text navigation.
/// Ctrl and ctrl+shift only; any alt or Win in the chord makes it nobody's
/// text chord. Ctrl+shift+arrows are deliberately NOT here: the Windows
/// defaults bind them to tab navigation, which has always answered from a
/// viewer.
pub fn pageOwns(vk: u16, mods: input.Mods) bool {
    if (!mods.ctrl or mods.alt or mods.super) return false;
    return switch (vk) {
        0x43, 0x56, 0x58, 0x41, 0x59 => !mods.shift, // C V X A Y
        0x5A => true, // Z, and ctrl+shift+Z (redo)
        // VK_LEFT/UP/RIGHT/DOWN, HOME, END, BACK, DELETE: word and line
        // movement and deletion in a text field.
        0x25, 0x26, 0x27, 0x28, 0x24, 0x23, 0x08, 0x2E => !mods.shift,
        else => false,
    };
}

/// Whether an action has a native handler for a focused viewer in
/// `Window.performViewerBindingAction` (T394). See `nativeTag`.
///
/// No arm here depends on the action's PAYLOAD — `close_tab:other` is
/// handled exactly as `close_tab:this` is — so the decision is really a
/// decision about the tag, and `nativeTag` is the form of it that a comptime
/// check can enumerate. `Window.performViewerBindingAction` uses that to
/// assert its dispatch switch handles everything this list admits, which is
/// what turns the gap T682 fixed (admitted, then quietly unhandled) into a
/// build failure instead of a log line nobody reads.
pub fn native(action: input.Binding.Action) bool {
    return nativeTag(std.meta.activeTag(action));
}

/// `native`, over the action's tag alone. Every tag here must be one the
/// core says needs no terminal (asserted by a test below).
pub fn nativeTag(tag: std.meta.Tag(input.Binding.Action)) bool {
    return switch (tag) {
        .quit,
        .new_window,
        .new_tab,
        .close_surface,
        .close_tab,
        .close_window,
        .close_all_windows,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .new_split,
        .goto_split,
        .swap_split,
        .resize_split,
        .equalize_splits,
        .toggle_split_zoom,
        // A viewer is a full citizen of the hero carousel (T397 gave it a
        // tile), so the chord that enters and leaves hero mode has to work
        // while one holds focus. Without this, a selected viewer swallowed
        // ctrl+shift+space into the page and the user could not leave hero
        // mode without first navigating to a terminal tile (T126).
        .toggle_hero_mode,
        // Same ground as hero mode: the mode belongs to the window, and a
        // viewer pane is one of the panes rearrange mode exists to move, so
        // a focused viewer must not swallow the chord (T1524).
        .toggle_rearrange_mode,
        // The pane sidebar is the window's column (T1828; Mac classifies the
        // action `.window` so a focused viewer forwards it).
        .toggle_pane_sidebar,
        // Stashing is a PANE action, so the core cannot perform it from here
        // (it would stash the host terminal instead) — the viewer itself is
        // what the user asked to put away (T1803).
        .stash_pane,
        .restore_stashed_pane,
        .toggle_fullscreen,
        .toggle_maximize,
        // The window's size is the window's, and a viewer-only window has no
        // terminal to press this from at all — so a bound "back to the
        // default size" chord has to answer from a focused viewer (T682).
        .reset_window_size,
        // The overview IS hero mode here (T708), and a viewer is a full
        // citizen of the carousel - so this chord has to answer from a
        // focused viewer for the same reason `toggle_hero_mode` above does.
        // It was forwarded before it meant anything (T682), on the narrower
        // ground that a chord a terminal pane CLAIMS must not leak into a
        // viewer's page; that still holds, and now it also does something.
        .toggle_tab_overview,
        .toggle_window_decorations,
        .toggle_command_palette,
        .open_config,
        .reload_config,
        .prompt_window_title,
        => true,

        else => false,
    };
}

// ------------------------------------------------------------- pane chords

/// A chord that belongs to a focused viewer pane itself rather than to the
/// app or the page (T161) — Mac's `ViewerView.PaneChord`, with the chords
/// remapped to the Windows defaults pinned in
/// `docs/design/viewer-panes-windows.md` P7.
pub const PaneChord = enum {
    /// ctrl+r — reload in place, the interactive `+reload`.
    reload,
    /// ctrl+d / ctrl+l / alt+d — focus and select the address field.
    focus_address,
    /// ctrl+f — open the find card and put the caret in it (T1184). Mac's
    /// Cmd+F, respelled the way every Windows application spells "find".
    find,
    /// ctrl+g / F3 — step to the next match without reaching for the card.
    /// Mac has only Cmd+G; Windows has both spellings and answers to both,
    /// because F3 is the one a Windows user reaches for without thinking and
    /// ctrl+g is the one a browser trained them on.
    find_next,
    /// ctrl+shift+g / shift+F3 — step to the previous match.
    find_previous,
};

/// Classify a chord as one of the viewer's pane-scoped chords, or null if it
/// is not one. Pure classification (no side effects) so the mapping is
/// unit-testable without a live pane — Mac's `paneChord(for:)`.
///
/// Each chord requires EXACTLY its modifier: ctrl+shift+r ("reload
/// bypassing cache" in browsers) is not claimed, ctrl+shift+d stays the
/// global split-down, and the Win key never participates. `ctrl+l` and
/// `alt+d` are Windows-native aliases for the address bar (every browser on
/// Windows answers to both); `ctrl+d` mirrors Mac's Cmd+D.
pub fn paneChord(vk: u16, mods: input.Mods) ?PaneChord {
    if (mods.super) return null;
    const ctrl_only = mods.ctrl and !mods.shift and !mods.alt;
    const alt_only = mods.alt and !mods.shift and !mods.ctrl;
    const ctrl_shift = mods.ctrl and mods.shift and !mods.alt;
    const shift_only = mods.shift and !mods.ctrl and !mods.alt;
    const bare = !mods.ctrl and !mods.shift and !mods.alt;
    return switch (vk) {
        0x52 => if (ctrl_only) .reload else null, // 'R'
        0x44 => if (ctrl_only or alt_only) .focus_address else null, // 'D'
        0x4C => if (ctrl_only) .focus_address else null, // 'L'
        0x46 => if (ctrl_only) .find else null, // 'F'
        // ctrl+g steps forward and ctrl+shift+g back — the browser pair, and
        // the same shape as Mac's Cmd+G / Cmd+Shift+G.
        0x47 => if (ctrl_only) .find_next else if (ctrl_shift) .find_previous else null, // 'G'
        // F3 / shift+F3, the Windows-native spelling of the same pair. BARE
        // F3 on purpose: a function key with no modifier is the whole point of
        // it, and a viewer pane has no other meaning for the key.
        0x72 => if (bare) .find_next else if (shift_only) .find_previous else null, // VK_F3
        else => null,
    };
}

// ---------------------------------------------------------------- composer

/// A chord that belongs to the viewer's FEEDBACK COMPOSER (T634) — live only
/// while keyboard focus is inside the composer itself, which on win32 means
/// the chord is classified from the composer window's own WndProc rather than
/// from the accelerator hop above. Mac's `ViewerFeedbackTextView` keys, with
/// Cmd-Enter respelled as the Windows Ctrl-Enter.
pub const ComposerChord = enum {
    /// ctrl+enter — send the report. Mac's ⌘↩.
    send,
    /// escape — close the composer, leaving its contents on the pane.
    close,
    /// ctrl+shift+s — take a screenshot into the report (T647). Mac's ⇧⌘S,
    /// respelled with ctrl. SHIFT is part of it on purpose: a bare ctrl+s in a
    /// text field means "save" to everyone, and there is nothing here to save.
    snapshot,
    /// tab — move keyboard focus to the next thing inside the composer:
    /// text → "+" → send → text (T640). A composer whose two actions can only
    /// be reached with a mouse is an accessibility defect, and Tab is the one
    /// key every Windows user already tries.
    focus_next,
    /// shift+tab — the same walk, backwards.
    focus_prev,
};

/// Classify a chord as one of the composer's, or null if it is not one —
/// including the case that matters most, PLAIN Enter, which inserts a newline
/// and must never be mistaken for a send (a composer that submits on Enter
/// cannot write a two-paragraph report).
///
/// Pure classification, so the table is unit-testable without a live pane.
/// Exact modifiers, the same rule `paneChord` follows: ctrl+shift+enter and
/// alt+escape are nobody's here.
pub fn composerChord(vk: u16, mods: input.Mods) ?ComposerChord {
    if (mods.super) return null;
    const bare = !mods.ctrl and !mods.shift and !mods.alt;
    const ctrl_only = mods.ctrl and !mods.shift and !mods.alt;
    const ctrl_shift = mods.ctrl and mods.shift and !mods.alt;
    const shift_only = mods.shift and !mods.ctrl and !mods.alt;
    return switch (vk) {
        0x0D => if (ctrl_only) .send else null, // VK_RETURN
        0x1B => if (bare) .close else null, // VK_ESCAPE
        0x53 => if (ctrl_shift) .snapshot else null, // 'S'
        // VK_TAB. Claimed here rather than left to the text surface because
        // the web composer's Chromium would move focus inside the page
        // instead of onto the two action buttons.
        0x09 => if (bare) .focus_next else if (shift_only) .focus_prev else null,
        else => null,
    };
}

// -------------------------------------------------------------------- zoom

/// A ctrl+plus/minus/0 keyboard-zoom request (T161). Pinch and ctrl+wheel
/// are Chromium's own and independent of this — Mac's `ZoomAction`, whose
/// step and clamp are copied exactly so the two clients zoom identically.
pub const ZoomAction = enum { zoom_in, zoom_out, reset };

/// Keyboard page-zoom bounds and per-press step. 1.0 is 100%. The same
/// values as `ViewerView.swift` (`minZoom`/`maxZoom`/`zoomStep`).
pub const min_zoom: f64 = 0.5;
pub const max_zoom: f64 = 3.0;
pub const zoom_step: f64 = 1.1;

/// Classify a chord as a viewer zoom action, or null if it is not one.
///
/// Matches the DEFAULT font-size chords (ctrl + `=`/`+`/`-`/`0`, main row
/// and numpad) — the same keys `Config.zig` binds to
/// increase/decrease/reset_font_size. Alt and Win are rejected so this
/// never collides with other chords. Shift is allowed only on the main-row
/// `=` key, because ctrl+shift+= is how a "+" is typed — the exact set Mac
/// accepts (its `charactersIgnoringModifiers` keeps shift, so `+` reads as
/// zoom-in while shift+`-` and shift+`0` produce other characters and fall
/// through).
pub fn zoomAction(vk: u16, mods: input.Mods) ?ZoomAction {
    if (!mods.ctrl or mods.alt or mods.super) return null;
    return switch (vk) {
        0xBB => .zoom_in, // VK_OEM_PLUS ('=' / shift '+')
        0x6B => if (mods.shift) null else .zoom_in, // VK_ADD (numpad +)
        0xBD => if (mods.shift) null else .zoom_out, // VK_OEM_MINUS
        0x6D => if (mods.shift) null else .zoom_out, // VK_SUBTRACT (numpad -)
        0x30 => if (mods.shift) null else .reset, // '0'
        0x60 => if (mods.shift) null else .reset, // VK_NUMPAD0
        else => null,
    };
}

/// The next page-zoom factor for an action, clamped to [min_zoom, max_zoom]
/// — Mac's `steppedZoom(from:action:)`, verbatim.
pub fn steppedZoom(current: f64, action: ZoomAction) f64 {
    return switch (action) {
        .zoom_in => @min(max_zoom, current * zoom_step),
        .zoom_out => @max(min_zoom, current / zoom_step),
        .reset => 1.0,
    };
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "a letter chord resolves a default-style unicode binding" {
    const alloc = testing.allocator;
    var set: input.Binding.Set = .{};
    defer set.deinit(alloc);

    // The shape the Windows defaults use: `ctrl+shift+p` parses to a
    // UNICODE trigger, not a physical one.
    try set.put(
        alloc,
        .{ .key = .{ .unicode = 'p' }, .mods = .{ .ctrl = true, .shift = true } },
        .toggle_command_palette,
    );

    const event = keyEventFor(0x50, false, .{ .ctrl = true, .shift = true }).?; // 'P'
    try testing.expectEqual(input.Key.key_p, event.key);
    try testing.expectEqual(@as(u21, 'p'), event.unshifted_codepoint);

    const entry = set.getEvent(event).?;
    try testing.expectEqual(
        input.Binding.Action.toggle_command_palette,
        entry.value_ptr.*.leaf.action,
    );
}

test "a physical-key chord resolves a physical binding" {
    const alloc = testing.allocator;
    var set: input.Binding.Set = .{};
    defer set.deinit(alloc);

    // The Windows default `ctrl+f4 = close_tab:this` is stored physical.
    try set.put(
        alloc,
        .{ .key = .{ .physical = .f4 }, .mods = .{ .ctrl = true } },
        .{ .close_tab = .this },
    );

    const event = keyEventFor(0x73, false, .{ .ctrl = true }).?; // VK_F4
    const entry = set.getEvent(event).?;
    try testing.expectEqual(
        input.Binding.Action{ .close_tab = .this },
        entry.value_ptr.*.leaf.action,
    );

    // The same vk without ctrl matches nothing.
    const bare = keyEventFor(0x73, false, .{}).?;
    try testing.expect(set.getEvent(bare) == null);
}

test "bare modifiers and unidentified keys build no event" {
    // A modifier press arrives as its own accelerator event and must never
    // consult the table (a `ctrl+w` binding would otherwise fire on the
    // ctrl press alone via catch_all bindings).
    try testing.expect(keyEventFor(0x10, false, .{ .shift = true }) == null); // VK_SHIFT
    try testing.expect(keyEventFor(0xA2, false, .{ .ctrl = true }) == null); // VK_LCONTROL
    try testing.expect(keyEventFor(0x5B, false, .{ .super = true }) == null); // VK_LWIN
    // 0x15 (VK_KANA) is not in the table: no key, no codepoint, no lookup.
    try testing.expect(keyEventFor(0x15, false, .{ .ctrl = true }) == null);
}

test "the extended bit distinguishes the numpad enter" {
    try testing.expectEqual(input.Key.enter, keyEventFor(0x0D, false, .{ .ctrl = true }).?.key);
    try testing.expectEqual(input.Key.numpad_enter, keyEventFor(0x0D, true, .{ .ctrl = true }).?.key);
}

test "paneChord: exact-modifier chords only" {
    // The pinned table: ctrl+r reload; ctrl+d / ctrl+l / alt+d address bar.
    const ctrl: input.Mods = .{ .ctrl = true };
    const alt: input.Mods = .{ .alt = true };
    try testing.expectEqual(PaneChord.reload, paneChord(0x52, ctrl).?);
    try testing.expectEqual(PaneChord.focus_address, paneChord(0x44, ctrl).?);
    try testing.expectEqual(PaneChord.focus_address, paneChord(0x4C, ctrl).?);
    try testing.expectEqual(PaneChord.focus_address, paneChord(0x44, alt).?);

    // Exactness: the neighboring global bindings stay untouched.
    try testing.expect(paneChord(0x52, .{ .ctrl = true, .shift = true }) == null); // ctrl+shift+r
    try testing.expect(paneChord(0x44, .{ .ctrl = true, .shift = true }) == null); // ctrl+shift+d = split down
    try testing.expect(paneChord(0x44, .{ .ctrl = true, .alt = true }) == null);
    try testing.expect(paneChord(0x44, .{ .alt = true, .shift = true }) == null);
    try testing.expect(paneChord(0x4C, alt) == null); // alt+l is nothing
    try testing.expect(paneChord(0x52, alt) == null); // alt+r is nothing
    try testing.expect(paneChord(0x52, .{}) == null); // bare 'r' is typing
    try testing.expect(paneChord(0x52, .{ .ctrl = true, .super = true }) == null);
}

test "T1184: the find chords, in both spellings Windows knows" {
    const ctrl: input.Mods = .{ .ctrl = true };
    const ctrl_shift: input.Mods = .{ .ctrl = true, .shift = true };
    const shift: input.Mods = .{ .shift = true };
    try testing.expectEqual(PaneChord.find, paneChord(0x46, ctrl).?); // ctrl+f
    try testing.expectEqual(PaneChord.find_next, paneChord(0x47, ctrl).?); // ctrl+g
    try testing.expectEqual(PaneChord.find_previous, paneChord(0x47, ctrl_shift).?);
    // F3 / shift+F3 — the pair a Windows user reaches for without thinking.
    try testing.expectEqual(PaneChord.find_next, paneChord(0x72, .{}).?);
    try testing.expectEqual(PaneChord.find_previous, paneChord(0x72, shift).?);

    // Exactness, the same rule the rest of the table follows. ctrl+shift+f is
    // nobody's here, bare 'f' and bare 'g' are typing, and ctrl+F3 is not a
    // spelling of anything.
    try testing.expect(paneChord(0x46, ctrl_shift) == null);
    try testing.expect(paneChord(0x46, .{}) == null);
    try testing.expect(paneChord(0x47, .{}) == null);
    try testing.expect(paneChord(0x47, .{ .alt = true }) == null);
    try testing.expect(paneChord(0x72, ctrl) == null);
    try testing.expect(paneChord(0x46, .{ .ctrl = true, .super = true }) == null);
}

test "composerChord: ctrl+enter sends, plain enter does not" {
    const ctrl: input.Mods = .{ .ctrl = true };
    try testing.expectEqual(ComposerChord.send, composerChord(0x0D, ctrl).?);
    try testing.expectEqual(ComposerChord.close, composerChord(0x1B, .{}).?);

    // The one that matters: a bare Enter is a NEWLINE, not a send. A
    // composer that submits on Enter cannot write a two-paragraph report.
    try testing.expect(composerChord(0x0D, .{}) == null);
    try testing.expect(composerChord(0x0D, .{ .shift = true }) == null);

    // Exactness, the same rule the pane chords follow.
    try testing.expect(composerChord(0x0D, .{ .ctrl = true, .shift = true }) == null);
    try testing.expect(composerChord(0x0D, .{ .ctrl = true, .alt = true }) == null);
    try testing.expect(composerChord(0x0D, .{ .ctrl = true, .super = true }) == null);
    try testing.expect(composerChord(0x1B, ctrl) == null);
    try testing.expect(composerChord(0x1B, .{ .alt = true }) == null);

    // ctrl+shift+s captures a screenshot (Mac's shift+cmd+S). Shift is
    // REQUIRED: a bare ctrl+s in a text field reads as "save", and typing an
    // 's' must obviously never take a picture.
    try testing.expectEqual(
        ComposerChord.snapshot,
        composerChord(0x53, .{ .ctrl = true, .shift = true }).?,
    );
    try testing.expect(composerChord(0x53, ctrl) == null);
    try testing.expect(composerChord(0x53, .{ .shift = true }) == null);
    try testing.expect(composerChord(0x53, .{}) == null);
    try testing.expect(composerChord(0x53, .{ .ctrl = true, .shift = true, .alt = true }) == null);
    try testing.expect(composerChord(0x53, .{ .ctrl = true, .shift = true, .super = true }) == null);

    // Tab walks the composer's focus ring, shift+Tab walks it back (T640).
    // Bare and shift-only, exactly: ctrl+tab is the tab strip's and alt+tab is
    // the shell's, and neither may be eaten by a text box.
    try testing.expectEqual(ComposerChord.focus_next, composerChord(0x09, .{}).?);
    try testing.expectEqual(
        ComposerChord.focus_prev,
        composerChord(0x09, .{ .shift = true }).?,
    );
    try testing.expect(composerChord(0x09, ctrl) == null);
    try testing.expect(composerChord(0x09, .{ .ctrl = true, .shift = true }) == null);
    try testing.expect(composerChord(0x09, .{ .alt = true }) == null);
    try testing.expect(composerChord(0x09, .{ .super = true }) == null);

    // And nothing else is a composer chord — typing must reach the buffer.
    try testing.expect(composerChord(0x41, .{}) == null); // 'A'
    try testing.expect(composerChord(0x08, .{}) == null); // backspace
    try testing.expect(composerChord(0x52, ctrl) == null); // ctrl+r stays the pane's
}

test "zoomAction: the default font-size chords, main row and numpad" {
    const ctrl: input.Mods = .{ .ctrl = true };
    const ctrl_shift: input.Mods = .{ .ctrl = true, .shift = true };
    try testing.expectEqual(ZoomAction.zoom_in, zoomAction(0xBB, ctrl).?); // ctrl+=
    try testing.expectEqual(ZoomAction.zoom_in, zoomAction(0xBB, ctrl_shift).?); // ctrl+shift+= is "+"
    try testing.expectEqual(ZoomAction.zoom_in, zoomAction(0x6B, ctrl).?); // ctrl+numpad+
    try testing.expectEqual(ZoomAction.zoom_out, zoomAction(0xBD, ctrl).?); // ctrl+-
    try testing.expectEqual(ZoomAction.zoom_out, zoomAction(0x6D, ctrl).?); // ctrl+numpad-
    try testing.expectEqual(ZoomAction.reset, zoomAction(0x30, ctrl).?); // ctrl+0
    try testing.expectEqual(ZoomAction.reset, zoomAction(0x60, ctrl).?); // ctrl+numpad0

    // Shift participates only in typing "+" (Mac's exact acceptance set).
    try testing.expect(zoomAction(0xBD, ctrl_shift) == null);
    try testing.expect(zoomAction(0x30, ctrl_shift) == null);
    try testing.expect(zoomAction(0x6B, ctrl_shift) == null);
    // No ctrl, or alt/win present: not a zoom chord.
    try testing.expect(zoomAction(0xBB, .{}) == null);
    try testing.expect(zoomAction(0xBB, .{ .ctrl = true, .alt = true }) == null);
    try testing.expect(zoomAction(0xBB, .{ .ctrl = true, .super = true }) == null);
}

test "steppedZoom: Mac's step and clamp, verbatim" {
    // One press up from 100% is 110%.
    try testing.expectApproxEqAbs(@as(f64, 1.1), steppedZoom(1.0, .zoom_in), 1e-9);
    // One press down from 100% is 1/1.1.
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 1.1), steppedZoom(1.0, .zoom_out), 1e-9);
    // Reset lands exactly on 1.0 from anywhere.
    try testing.expectEqual(@as(f64, 1.0), steppedZoom(2.37, .reset));
    // Stepping up from near the ceiling clamps at 3.0 and stays there.
    try testing.expectEqual(max_zoom, steppedZoom(2.9, .zoom_in));
    try testing.expectEqual(max_zoom, steppedZoom(max_zoom, .zoom_in));
    // Stepping down from near the floor clamps at 0.5 and stays there.
    try testing.expectEqual(min_zoom, steppedZoom(0.52, .zoom_out));
    try testing.expectEqual(min_zoom, steppedZoom(min_zoom, .zoom_out));
}

fn single(action: input.Binding.Action, flags: input.Binding.Flags) input.Binding.Set.GenericLeaf {
    return .{ .flags = flags, .actions = .{ .single = .{action} } };
}

fn routeOf(action: input.Binding.Action, has_host: bool) Route {
    const leaf = single(action, .{});
    return route(&leaf, has_host);
}

test "native: window/app commands yes, terminal-content commands no" {
    // The exact chords the user lost (2026-08-05): close, and the palette.
    try testing.expect(native(.close_surface));
    try testing.expect(native(.{ .close_tab = .this }));
    try testing.expect(native(.toggle_command_palette));
    try testing.expect(native(.new_tab));
    try testing.expect(native(.{ .new_split = .right }));
    try testing.expect(native(.{ .goto_split = .right }));
    try testing.expect(native(.quit));

    // Hero mode: the nav chords were already forwarded, so a viewer that
    // could be navigated INTO but not out of was the one-way door T126
    // found. All three of hero's chords answer from a focused viewer.
    try testing.expect(native(.toggle_hero_mode));
    try testing.expect(native(.{ .swap_split = .down }));

    // Rearrange mode arrived on the same ground (T1524): window-scoped, and
    // a viewer pane is one of the panes it exists to move.
    try testing.expect(native(.toggle_rearrange_mode));

    // The two the same sweep left behind (T682). Both are the WINDOW's, and
    // a viewer-only window has no terminal to press them from at all.
    try testing.expect(native(.reset_window_size));
    try testing.expect(native(.toggle_tab_overview));

    // Stash acts on the viewer itself (T1803).
    try testing.expect(native(.stash_pane));
    try testing.expect(native(.restore_stashed_pane));

    // Content-scoped actions have no native handler.
    try testing.expect(!native(.{ .copy_to_clipboard = .mixed }));
    try testing.expect(!native(.paste_from_clipboard));
    try testing.expect(!native(.scroll_page_up));
    try testing.expect(!native(.{ .increase_font_size = 1 }));
    try testing.expect(!native(.select_all));
    try testing.expect(!native(.start_search));
    try testing.expect(!native(.clear_screen));
    try testing.expect(!native(.prompt_surface_banner));
}

test "native is decided by the tag, not the payload" {
    // Every arm of the list is payload-independent, which is what lets
    // `Window.performViewerBindingAction` assert its dispatch switch against
    // `nativeTag` over the whole tag space at compile time (T682). If some
    // future action ever needs a handler on one payload and not another,
    // this test is where that shows up first.
    inline for (@typeInfo(input.Binding.Action).@"union".fields) |field| {
        const tag = @field(std.meta.Tag(input.Binding.Action), field.name);
        if (field.type == void) {
            const action = @unionInit(input.Binding.Action, field.name, {});
            try testing.expectEqual(nativeTag(tag), native(action));
        }
    }

    // The payload-carrying ones the viewer path actually uses, both ways.
    try testing.expectEqual(native(.{ .close_tab = .this }), native(.{ .close_tab = .other }));
    try testing.expectEqual(native(.{ .new_split = .up }), native(.{ .new_split = .auto }));
    try testing.expectEqual(
        native(.{ .increase_font_size = 1 }),
        native(.{ .increase_font_size = 4 }),
    );
}

test "T1803: no native handler is for an action that needs a terminal" {
    // The core's classification is the authority; a native arm for a
    // terminal action would perform it on a pane that has no terminal state.
    inline for (@typeInfo(input.Binding.Action).@"union".fields) |field| {
        const tag = @field(std.meta.Tag(input.Binding.Action), field.name);
        if (nativeTag(tag)) {
            const action = @unionInit(input.Binding.Action, field.name, undefined);
            try testing.expect(action.requires() != .terminal);
        }
    }
}

test "T1803: no terminal action is ever routed out of a viewer" {
    // Exhaustive over the action space, with and without a host terminal and
    // under every flag but global/all (which the core performs everywhere).
    // `text:` is the case that matters most: routed, it would type into a
    // shell the user is not looking at.
    inline for (@typeInfo(input.Binding.Action).@"union".fields) |field| {
        const action = @unionInit(input.Binding.Action, field.name, undefined);
        if (action.requires() == .terminal) {
            for ([_]bool{ false, true }) |host| {
                for ([_]bool{ false, true }) |performable| {
                    const leaf = single(action, .{ .performable = performable });
                    try testing.expectEqual(Route.pass, route(&leaf, host));
                }
            }
        }
    }
}

test "T1803: every action the core can perform from a viewer is routed" {
    // The gap the allowlist left: an app or window action nobody listed.
    // App actions route with or without a host terminal; window actions
    // need one unless a native handler exists; pane actions only natively.
    inline for (@typeInfo(input.Binding.Action).@"union".fields) |field| {
        const action = @unionInit(input.Binding.Action, field.name, undefined);
        const has_native = nativeTag(@field(std.meta.Tag(input.Binding.Action), field.name));
        switch (action.requires()) {
            .terminal => {},
            .app => {
                try testing.expect(routeOf(action, false) != .pass);
                try testing.expect(routeOf(action, true) != .pass);
            },
            .window => {
                try testing.expect(routeOf(action, true) != .pass);
                try testing.expectEqual(has_native, routeOf(action, false) != .pass);
            },
            .pane => {
                try testing.expectEqual(has_native, routeOf(action, true) != .pass);
                try testing.expectEqual(has_native, routeOf(action, false) != .pass);
            },
        }
        if (has_native) try testing.expectEqual(Route.native, routeOf(action, true));
    }

    // The ones the old allowlist missed, named.
    try testing.expectEqual(Route.core, routeOf(.{ .goto_window = .next }, true));
    try testing.expectEqual(Route.core, routeOf(.toggle_window_float_on_top, true));
    try testing.expectEqual(Route.core, routeOf(.toggle_quick_terminal, false));
    try testing.expectEqual(Route.core, routeOf(.check_for_updates, false));
    try testing.expectEqual(Route.pass, routeOf(.toggle_window_float_on_top, false));
    // A pane action with no native handler would act on the host terminal.
    try testing.expectEqual(Route.pass, routeOf(.prompt_surface_title, true));
}

test "T1803: chains route by their most demanding action" {
    const ok = [_]input.Binding.Action{ .new_tab, .toggle_fullscreen };
    const leaf_ok: input.Binding.Set.GenericLeaf = .{ .flags = .{}, .actions = .{ .many = &ok } };
    try testing.expectEqual(Route.core, route(&leaf_ok, true));
    try testing.expectEqual(Route.pass, route(&leaf_ok, false));

    const typing = [_]input.Binding.Action{ .new_tab, .{ .text = "ls\n" } };
    const leaf_typing: input.Binding.Set.GenericLeaf = .{ .flags = .{}, .actions = .{ .many = &typing } };
    try testing.expectEqual(Route.pass, route(&leaf_typing, true));

    // Global and all-surface bindings are not about the focused pane.
    const all = single(.{ .text = "x" }, .{ .all = true });
    try testing.expectEqual(Route.core, route(&all, false));
}

test "T1803: the page keeps its editing and text-navigation chords" {
    const ctrl: input.Mods = .{ .ctrl = true };
    const ctrl_shift: input.Mods = .{ .ctrl = true, .shift = true };
    for ([_]u16{ 0x43, 0x56, 0x58, 0x41, 0x5A, 0x59, 0x25, 0x27, 0x24, 0x23, 0x08, 0x2E }) |vk| {
        try testing.expect(pageOwns(vk, ctrl));
    }
    try testing.expect(pageOwns(0x5A, ctrl_shift)); // ctrl+shift+z = redo

    // Not text chords: tab navigation on ctrl+shift+arrows (a Windows
    // default), anything with alt or Win, bare keys, and other letters.
    try testing.expect(!pageOwns(0x25, ctrl_shift));
    try testing.expect(!pageOwns(0x27, ctrl_shift));
    try testing.expect(!pageOwns(0x43, ctrl_shift));
    try testing.expect(!pageOwns(0x25, .{ .ctrl = true, .alt = true }));
    try testing.expect(!pageOwns(0x43, .{ .ctrl = true, .super = true }));
    try testing.expect(!pageOwns(0x43, .{}));
    try testing.expect(!pageOwns(0x54, ctrl)); // ctrl+t
    try testing.expect(!pageOwns(0x31, ctrl)); // ctrl+1 (goto_tab)
}
