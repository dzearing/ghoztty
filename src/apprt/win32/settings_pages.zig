//! The Settings window's curated pages (T2585) - the win32 port of Mac
//! `SettingsPages.swift` (9287de0ff, with 3a183ffd1's Terminal page that no
//! longer carries `env`).
//!
//! Presentation only: which keys go on which page, in what order, with what
//! label and control. Docs, defaults, enum options and validation all come
//! from the schema (`SettingsCatalog`), and the drift test at the foot of
//! this file fails when a key or an option named here drifts from
//! `Config.zig`, or a key sits on two pages - Mac's `SettingsPagesTests`.
//! Every key not curated here still appears under Advanced > All Settings.
//!
//! Where the table differs from Mac's, it is because the setting does not
//! exist on Windows, never because the Windows window is unfinished:
//!
//! - Keyboard drops Mac's three keys (`macos-option-as-alt`,
//!   `macos-shortcuts`, `macos-auto-secure-input`): each drives a macOS-only
//!   facility (the Option key, the Shortcuts app, Secure Keyboard Entry) that
//!   the win32 runtime never reads. The page keeps the shortcut guide card,
//!   which is what Mac's page shows first.
//! - Updates drops `auto-update-channel`: the Windows updater follows the
//!   published `win-v*` releases and has no tip channel to pick.
//! - Copy & paste labels `copy-on-select = true` "On" rather than Mac's "To
//!   the selection clipboard": Windows has no separate selection clipboard.
//! - "Shell for scripted windows" names the Windows shell flavors in its hint
//!   instead of Mac's `-lic`.
//! - Appearance > Window drops `background-blur` and `macos-titlebar-style`:
//!   the win32 renderer never blurs the terminal background (Mac's blur is a
//!   CoreAnimation/glass facility) and the title bar is Ghoztty's own tab
//!   strip, not an AppKit titlebar with styles to pick.
//! - Balance padding is a three-way choice (Off / On / Centered), not Mac's
//!   switch: `window-padding-balance` is an enum with `equal` as its third
//!   value, which a switch cannot reach (the drift test refuses a toggle on
//!   a non-bool key).
//! - The Font row edits `font-family` as its list of names (Mac draws a font
//!   picker); the key, label and placement are Mac's.
const std = @import("std");

pub const PageId = enum { appearance, panes, terminal, keyboard, session, remote, updates, advanced };

/// A (value, label) pair for a picker. A "" value means "unset" - choosing
/// it removes the key from the user's file.
pub const Option = struct { value: []const u8, label: []const u8 };

pub const Control = union(enum) {
    toggle,
    /// A popup. Schema options without a curated label are added with their
    /// raw name, so a new enum value still shows up.
    picker: []const Option,
    /// Mac's segmented control; drawn as the same popup on Windows.
    segmented: []const Option,
    /// Mac's Pane style preview cards (T2680): one clickable thumbnail per
    /// option, the chosen one ringed in the accent.
    cards: []const Option,
    slider: struct { min: f64, max: f64, step: f64, percent: bool = true, inverted: bool = false },
    stepper: struct { min: f64, max: f64, step: f64, unit: []const u8 },
    /// A size in bytes, shown as megabytes.
    megabytes: struct { max: f64 },
    color: struct { none_label: []const u8 },
    text: struct { placeholder: []const u8 },
    list: struct { placeholder: []const u8 },
    /// A font family (Mac's font picker); edited as the key's value list.
    font,
    flags,
    shell: struct { scripted: bool },
    folder,

    /// The curated picker options, or null for any other control.
    pub fn options(self: Control) ?[]const Option {
        return switch (self) {
            .picker, .segmented, .cards => |o| o,
            else => null,
        };
    }

    /// A control drawn as an on/off switch or a value popup (the rest edit
    /// the value as text, the All Settings way).
    pub fn isChoice(self: Control) bool {
        return switch (self) {
            .toggle, .picker, .segmented, .cards => true,
            else => false,
        };
    }
};

/// Dim the row unless `key` has `equals` (or, with `less_than`, is below it).
pub const Condition = struct {
    key: []const u8,
    equals: ?[]const u8 = null,
    less_than: ?f64 = null,
    reason: []const u8,

    /// Whether the condition holds for `value` (the key's effective value).
    pub fn holds(self: Condition, value: []const u8) bool {
        if (self.equals) |want| return std.mem.eql(u8, value, want);
        if (self.less_than) |limit| {
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " ")) catch return false;
            return v < limit;
        }
        return true;
    }
};

pub const Row = struct {
    key: []const u8,
    label: []const u8,
    control: Control,
    /// Shown instead of the doc summary.
    hint: ?[]const u8 = null,
    enabled_when: ?Condition = null,

    /// The label a value reads as on this row: the curated label, else the
    /// raw value (a schema option nobody curated yet).
    pub fn labelFor(self: *const Row, value: []const u8) []const u8 {
        if (self.control == .toggle) {
            return if (std.mem.eql(u8, value, "true")) "On" else "Off";
        }
        if (self.control.options()) |opts| for (opts) |o| {
            if (std.mem.eql(u8, o.value, value)) return o.label;
        };
        return value;
    }
};

/// Sections with their own UI (Mac `SettingsCustomSection`). Only the ones
/// a Windows curated page carries are listed.
pub const Custom = enum {
    /// The theme picker (Mac `ThemeSection`): one theme, or a light and a
    /// dark one that follow the system appearance.
    theme,
    shortcut_guide,
    agent_status,
    remote_machines,
    version,
    config_file,
    all_settings,

    /// Words search should match for the section (Mac `searchText`).
    pub fn searchText(self: Custom) []const u8 {
        return switch (self) {
            .theme => "theme colors light dark mode appearance",
            .shortcut_guide => "keyboard shortcuts keybind guide",
            .agent_status => "agent session persistence status pipe",
            .remote_machines => "remote machines relay ssh host",
            .version => "version update check",
            .config_file => "config file open editor backup include",
            .all_settings => "all settings raw advanced",
        };
    }
};

pub const Section = struct {
    title: ?[]const u8 = null,
    footer: ?[]const u8 = null,
    rows: []const Row = &.{},
    custom: ?Custom = null,
};

pub const Page = struct {
    id: PageId,
    title: []const u8,
    /// Drawn on the page's tinted tile (Mac: an SF Symbol on a gradient).
    glyph: []const u8,
    /// The tile's tint, 0xRRGGBB (Mac's `tint`).
    tint: u32,
    sections: []const Section,
};

const ask_allow_deny = [_]Option{
    .{ .value = "ask", .label = "Ask" },
    .{ .value = "allow", .label = "Allow" },
    .{ .value = "deny", .label = "Deny" },
};

pub const appearance: Page = .{
    .id = .appearance,
    .title = "Appearance",
    .glyph = "\u{25D0}",
    .tint = 0x5856D6,
    .sections = &.{
        .{ .title = "Theme", .custom = .theme },
        .{ .title = "Font", .rows = &.{
            .{ .key = "font-family", .label = "Font", .control = .font },
            .{ .key = "font-size", .label = "Size", .control = .{ .stepper = .{ .min = 6, .max = 72, .step = 0.5, .unit = "pt" } } },
            .{ .key = "font-feature", .label = "Font features", .control = .{ .list = .{ .placeholder = "-calt" } }, .hint = "OpenType features, e.g. -calt turns off ligatures, ss01 picks a stylistic set." },
            .{ .key = "font-thicken", .label = "Thicken strokes", .control = .toggle },
            .{ .key = "adjust-cell-height", .label = "Line height adjustment", .control = .{ .text = .{ .placeholder = "0 or 10%" } } },
        } },
        .{ .title = "Cursor", .rows = &.{
            .{ .key = "cursor-style", .label = "Style", .control = .{ .segmented = &.{
                .{ .value = "block", .label = "Block" },
                .{ .value = "bar", .label = "Bar" },
                .{ .value = "underline", .label = "Underline" },
                .{ .value = "block_hollow", .label = "Hollow" },
            } } },
            .{ .key = "cursor-style-blink", .label = "Blink", .control = .{ .segmented = &.{
                .{ .value = "", .label = "App decides" },
                .{ .value = "true", .label = "On" },
                .{ .value = "false", .label = "Off" },
            } } },
            .{ .key = "cursor-color", .label = "Color", .control = .{ .color = .{ .none_label = "Theme" } } },
            .{ .key = "cursor-opacity", .label = "Opacity", .control = .{ .slider = .{ .min = 0, .max = 1, .step = 0.05 } } },
        } },
        .{ .title = "Window", .rows = &.{
            .{ .key = "background-opacity", .label = "Background opacity", .control = .{ .slider = .{ .min = 0, .max = 1, .step = 0.01 } } },
            .{ .key = "window-padding-x", .label = "Horizontal padding", .control = .{ .stepper = .{ .min = 0, .max = 80, .step = 1, .unit = "pt" } } },
            .{ .key = "window-padding-y", .label = "Vertical padding", .control = .{ .stepper = .{ .min = 0, .max = 80, .step = 1, .unit = "pt" } } },
            .{ .key = "window-padding-balance", .label = "Balance padding", .control = .{ .segmented = &.{
                .{ .value = "false", .label = "Off" },
                .{ .value = "true", .label = "On" },
                .{ .value = "equal", .label = "Centered" },
            } } },
            .{ .key = "window-theme", .label = "Window appearance", .control = .{ .picker = &.{
                .{ .value = "auto", .label = "Match the theme" },
                .{ .value = "system", .label = "Follow the system" },
                .{ .value = "light", .label = "Light" },
                .{ .value = "dark", .label = "Dark" },
                .{ .value = "ghostty", .label = "Ghostty" },
            } } },
        } },
    },
};

pub const panes: Page = .{
    .id = .panes,
    .title = "Panes & Windows",
    .glyph = "\u{25EB}",
    .tint = 0x30B0C7,
    .sections = &.{
        .{ .title = "Pane style", .rows = &.{
            .{ .key = "macos-pane-style", .label = "Pane style", .control = .{ .cards = &.{
                .{ .value = "elevated", .label = "Elevated" },
                .{ .value = "flat", .label = "Flat" },
            } } },
        } },
        .{ .rows = &.{
            .{ .key = "macos-pane-glass", .label = "Glass panes", .control = .toggle, .enabled_when = .{ .key = "macos-pane-style", .equals = "elevated", .reason = "Elevated style only" } },
            .{ .key = "unfocused-split-opacity", .label = "Dim unfocused panes", .control = .{ .slider = .{ .min = 0.15, .max = 1, .step = 0.05, .inverted = true } } },
            .{ .key = "unfocused-split-fill", .label = "Dimming color", .control = .{ .color = .{ .none_label = "Background" } } },
            .{ .key = "split-divider-color", .label = "Divider color", .control = .{ .color = .{ .none_label = "Automatic" } }, .enabled_when = .{ .key = "macos-pane-style", .equals = "flat", .reason = "Flat style only" } },
        } },
        .{ .title = "Window gradient", .rows = &.{
            .{ .key = "macos-window-gradient", .label = "New windows", .control = .{ .segmented = &.{
                .{ .value = "random", .label = "Random color" },
                .{ .value = "ocean", .label = "Ocean" },
            } }, .enabled_when = .{ .key = "macos-pane-style", .equals = "elevated", .reason = "Elevated style only" } },
        } },
        .{ .title = "Pane sidebar", .rows = &.{
            .{ .key = "macos-pane-sidebar", .label = "Sidebar in new windows", .control = .{ .picker = &.{
                .{ .value = "remember", .label = "Same as the last window" },
                .{ .value = "expanded", .label = "Expanded" },
                .{ .value = "collapsed", .label = "Collapsed to a rail" },
                .{ .value = "hidden", .label = "Hidden" },
            } } },
        } },
        .{ .title = "Stacked panes", .rows = &.{
            .{ .key = "macos-pane-min-width", .label = "Stack panes narrower than", .control = .{ .stepper = .{ .min = 120, .max = 800, .step = 5, .unit = "px" } } },
            .{ .key = "macos-pane-min-height", .label = "Stack panes shorter than", .control = .{ .stepper = .{ .min = 80, .max = 600, .step = 5, .unit = "px" } } },
        } },
        .{ .title = "Hero layout", .rows = &.{
            .{ .key = "macos-hero-carousel-ratio", .label = "Carousel width", .control = .{ .slider = .{ .min = 0.1, .max = 0.6, .step = 0.05 } } },
        } },
        .{ .title = "New windows", .rows = &.{
            .{ .key = "maximize", .label = "Open windows filling the screen", .control = .toggle },
            .{ .key = "window-inherit-font-size", .label = "Keep the current font size", .control = .toggle },
            .{ .key = "window-new-tab-position", .label = "New tab position", .control = .{ .picker = &.{
                .{ .value = "current", .label = "After the current tab" },
                .{ .value = "end", .label = "At the end" },
            } } },
            .{ .key = "window-save-state", .label = "Reopen windows at launch", .control = .{ .picker = &.{
                .{ .value = "default", .label = "System default" },
                .{ .value = "always", .label = "Always" },
                .{ .value = "never", .label = "Never" },
            } } },
            .{ .key = "confirm-close-surface", .label = "Confirm before closing", .control = .{ .picker = &.{
                .{ .value = "true", .label = "When a process is running" },
                .{ .value = "always", .label = "Always" },
                .{ .value = "false", .label = "Never" },
            } } },
        } },
    },
};

pub const terminal: Page = .{
    .id = .terminal,
    .title = "Terminal",
    .glyph = ">_",
    .tint = 0x4D4D4D,
    .sections = &.{
        .{ .title = "Shell", .rows = &.{
            .{ .key = "command", .label = "Shell", .control = .{ .shell = .{ .scripted = false } } },
            .{ .key = "working-directory", .label = "Start new windows in", .control = .folder },
            .{ .key = "window-inherit-working-directory", .label = "New windows open in the current folder", .control = .toggle },
            .{ .key = "split-inherit-working-directory", .label = "New panes open in the current folder", .control = .toggle },
            .{ .key = "tab-inherit-working-directory", .label = "New tabs open in the current folder", .control = .toggle },
            .{ .key = "command-shell", .label = "Shell for scripted windows", .control = .{ .shell = .{ .scripted = true } }, .hint = "Runs the command of ghoztty +new-window --command=\u{2026} through this shell (pwsh -NoExit -Command, cmd /K or wsl --)." },
        } },
        .{ .title = "Scrollback", .rows = &.{
            .{ .key = "scrollback-limit", .label = "Scrollback size", .control = .{ .megabytes = .{ .max = 4096 } } },
            .{ .key = "scrollbar", .label = "Scroll bar", .control = .{ .picker = &.{
                .{ .value = "system", .label = "System setting" },
                .{ .value = "never", .label = "Never" },
            } } },
        } },
        .{ .title = "Shell integration", .rows = &.{
            .{ .key = "shell-integration", .label = "Shell", .control = .{ .picker = &.{
                .{ .value = "detect", .label = "Detect automatically" },
                .{ .value = "none", .label = "Off" },
                .{ .value = "bash", .label = "bash" },
                .{ .value = "zsh", .label = "zsh" },
                .{ .value = "fish", .label = "fish" },
                .{ .value = "elvish", .label = "elvish" },
                .{ .value = "nushell", .label = "nushell" },
            } } },
            .{ .key = "shell-integration-features", .label = "Features", .control = .flags },
        } },
        .{ .title = "Copy & paste", .rows = &.{
            .{ .key = "copy-on-select", .label = "Copy on select", .control = .{ .picker = &.{
                .{ .value = "true", .label = "On" },
                .{ .value = "clipboard", .label = "To the system clipboard" },
                .{ .value = "false", .label = "Off" },
            } } },
            .{ .key = "clipboard-trim-trailing-spaces", .label = "Trim trailing spaces", .control = .toggle },
            .{ .key = "clipboard-paste-protection", .label = "Warn before pasting commands", .control = .toggle },
            .{ .key = "clipboard-read", .label = "Apps reading the clipboard", .control = .{ .segmented = &ask_allow_deny } },
            .{ .key = "clipboard-write", .label = "Apps writing the clipboard", .control = .{ .segmented = &ask_allow_deny } },
        } },
        .{ .title = "Mouse & links", .rows = &.{
            .{ .key = "mouse-hide-while-typing", .label = "Hide the pointer while typing", .control = .toggle },
            .{ .key = "focus-follows-mouse", .label = "Focus follows the mouse", .control = .toggle },
            .{ .key = "right-click-action", .label = "Right click", .control = .{ .picker = &.{
                .{ .value = "context-menu", .label = "Context menu" },
                .{ .value = "paste", .label = "Paste" },
                .{ .value = "copy", .label = "Copy" },
                .{ .value = "copy-or-paste", .label = "Copy or paste" },
                .{ .value = "ignore", .label = "Nothing" },
            } } },
            .{ .key = "link-url", .label = "Detect links", .control = .toggle },
            .{ .key = "mouse-scroll-multiplier", .label = "Scroll speed", .control = .{ .text = .{ .placeholder = "precision:1,discrete:3" } } },
        } },
        .{ .title = "Notifications", .rows = &.{
            .{ .key = "notify-on-command-finish", .label = "Notify when a command finishes", .control = .{ .picker = &.{
                .{ .value = "never", .label = "Never" },
                .{ .value = "unfocused", .label = "When unfocused" },
                .{ .value = "always", .label = "Always" },
            } } },
            .{ .key = "notify-on-command-finish-after", .label = "Only for commands longer than", .control = .{ .text = .{ .placeholder = "5s" } } },
        } },
    },
};

pub const keyboard: Page = .{
    .id = .keyboard,
    .title = "Keyboard",
    .glyph = "\u{2328}",
    .tint = 0x8E8E93,
    .sections = &.{
        .{ .custom = .shortcut_guide },
    },
};

pub const session: Page = .{
    .id = .session,
    .title = "Sessions & Agent",
    .glyph = "\u{21BB}",
    .tint = 0x34C759,
    .sections = &.{
        .{ .title = "Session persistence", .rows = &.{
            .{ .key = "session-persistence", .label = "Keep shells running when the app quits", .control = .toggle },
            .{ .key = "session-relaunch", .label = "After a reboot, panes", .control = .{ .picker = &.{
                .{ .value = "restore", .label = "Reopen as a shell in the same folder" },
                .{ .value = "rerun", .label = "Re-run their command" },
                .{ .value = "prompt", .label = "Ask each time" },
            } }, .enabled_when = .{ .key = "session-persistence", .equals = "true", .reason = "Needs session persistence" } },
            .{ .key = "claude-code-fullscreen", .label = "Claude Code full-screen mode", .control = .toggle },
        } },
        .{ .title = "Agent", .custom = .agent_status },
    },
};

pub const remote: Page = .{
    .id = .remote,
    .title = "Remote Machines",
    .glyph = "\u{21C4}",
    .tint = 0xFF9500,
    .sections = &.{
        .{ .custom = .remote_machines },
    },
};

pub const updates: Page = .{
    .id = .updates,
    .title = "Updates",
    .glyph = "\u{2193}",
    .tint = 0x007AFF,
    .sections = &.{
        .{ .rows = &.{
            .{ .key = "auto-update", .label = "Automatic updates", .control = .{ .picker = &.{
                .{ .value = "", .label = "System default" },
                .{ .value = "check", .label = "Check and notify" },
                .{ .value = "download", .label = "Download and install" },
                .{ .value = "off", .label = "Off" },
            } } },
        } },
        .{ .custom = .version },
    },
};

pub const advanced: Page = .{
    .id = .advanced,
    .title = "Advanced",
    .glyph = "\u{22EF}",
    .tint = 0x666666,
    .sections = &.{
        .{ .title = "Config file", .custom = .config_file },
        .{ .title = "All settings", .footer = "Every option, straight from the config schema.", .custom = .all_settings },
    },
};

/// The sidebar, in order (Mac's).
pub const all = [_]*const Page{ &appearance, &panes, &terminal, &keyboard, &session, &remote, &updates, &advanced };

pub fn page(id: PageId) *const Page {
    for (all) |p| if (p.id == id) return p;
    unreachable;
}

/// The page that curates `key`, if any (never `.advanced`).
pub fn pageFor(key: []const u8) ?PageId {
    for (all) |p| for (p.sections) |s| for (s.rows) |r| {
        if (std.mem.eql(u8, r.key, key)) return p.id;
    };
    return null;
}

/// The curated row for `key`, if any.
pub fn rowFor(key: []const u8) ?*const Row {
    for (all) |p| for (p.sections) |s| for (s.rows) |*r| {
        if (std.mem.eql(u8, r.key, key)) return r;
    };
    return null;
}

/// Whether some curated page edits `key` (Mac `curatedKeys.contains`).
pub fn isCurated(key: []const u8) bool {
    return pageFor(key) != null;
}

/// What a row's value popup lists: the curated options in order, then any
/// schema option nobody curated, under its raw name (Mac: "a new enum value
/// still shows up"). A toggle lists On and Off. Caller owns the slice; the
/// strings are borrowed.
pub fn choices(alloc: std.mem.Allocator, row: *const Row, schema_options: ?[]const []const u8) std.mem.Allocator.Error![]Option {
    var out: std.ArrayListUnmanaged(Option) = .empty;
    errdefer out.deinit(alloc);
    if (row.control == .toggle) {
        try out.append(alloc, .{ .value = "true", .label = "On" });
        try out.append(alloc, .{ .value = "false", .label = "Off" });
        return out.toOwnedSlice(alloc);
    }
    const curated = row.control.options() orelse &.{};
    try out.appendSlice(alloc, curated);
    if (schema_options) |so| for (so) |v| {
        var have = false;
        for (curated) |o| if (std.mem.eql(u8, o.value, v)) {
            have = true;
        };
        if (!have) try out.append(alloc, .{ .value = v, .label = v });
    };
    return out.toOwnedSlice(alloc);
}

/// Whether `row` matches a search: its label, key, hint, curated option
/// values and labels (Mac `rowMatches`; the caller adds docs and values).
pub fn rowMatchesText(row: *const Row, query: []const u8) bool {
    const contains = @import("SettingsCatalog.zig").containsIgnoreCase;
    if (contains(row.label, query) or contains(row.key, query)) return true;
    if (row.hint) |h| if (contains(h, query)) return true;
    if (row.control.options()) |opts| for (opts) |o| {
        if (contains(o.value, query) or contains(o.label, query)) return true;
    };
    return false;
}

// ---------------------------------------------------------------------
// Tests: Mac `SettingsPagesTests`, against this build's schema.
// ---------------------------------------------------------------------

const testing = std.testing;
const SettingsCatalog = @import("SettingsCatalog.zig");

test "settings_pages: every curated key and option is in the schema" {
    var cat = try SettingsCatalog.defaults(testing.allocator);
    defer cat.deinit();
    for (all) |p| for (p.sections) |s| for (s.rows) |r| {
        const e = cat.get(r.key) orelse {
            std.debug.print("curated key {s} (page {s}) is not in the schema\n", .{ r.key, p.title });
            return error.TestUnexpectedResult;
        };
        if (r.control == .toggle and e.kind != .bool) {
            std.debug.print("{s} is a toggle but its kind is {s}\n", .{ r.key, @tagName(e.kind) });
            return error.TestUnexpectedResult;
        }
        if (r.control.options()) |opts| for (opts) |o| {
            if (o.value.len == 0) {
                // "unset" only makes sense on an optional key.
                try testing.expect(e.optional);
                continue;
            }
            const ok = if (e.options) |schema_opts| blk: {
                for (schema_opts) |so| if (std.mem.eql(u8, so, o.value)) break :blk true;
                break :blk false;
            } else e.kind == .bool and (std.mem.eql(u8, o.value, "true") or std.mem.eql(u8, o.value, "false"));
            if (!ok) {
                std.debug.print("{s}: curated option '{s}' is not a schema option\n", .{ r.key, o.value });
                return error.TestUnexpectedResult;
            }
        };
    };
}

test "settings_pages: no key is on two pages, env is on none" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    for (all) |p| for (p.sections) |s| for (s.rows) |r| {
        const gop = try seen.getOrPut(testing.allocator, r.key);
        if (gop.found_existing) {
            std.debug.print("{s} is curated twice\n", .{r.key});
            return error.TestUnexpectedResult;
        }
    };
    // Mac 3a183ffd1: environment belongs in the shell's profile, so `env`
    // stays only under All Settings.
    try testing.expect(!isCurated("env"));
    try testing.expectEqual(PageId.appearance, pageFor("font-family").?);
    try testing.expectEqual(PageId.appearance, pageFor("window-theme").?);
}

test "settings_pages: Mac-only keys stay off the Windows pages" {
    for ([_][]const u8{ "macos-option-as-alt", "macos-shortcuts", "macos-auto-secure-input", "auto-update-channel", "macos-titlebar-style", "background-blur" }) |k| {
        try testing.expect(!isCurated(k));
    }
}

test "settings_pages: lookups, labels and conditions" {
    try testing.expectEqual(PageId.terminal, pageFor("scrollback-limit").?);
    try testing.expectEqual(PageId.session, pageFor("session-relaunch").?);
    const r = rowFor("right-click-action").?;
    try testing.expectEqualStrings("Nothing", r.labelFor("ignore"));
    try testing.expectEqualStrings("brand-new", r.labelFor("brand-new"));
    try testing.expectEqualStrings("On", rowFor("maximize").?.labelFor("true"));
    try testing.expectEqualStrings("Off", rowFor("maximize").?.labelFor("false"));
    const c: Condition = .{ .key = "x", .less_than = 1, .reason = "" };
    try testing.expect(c.holds("0.5"));
    try testing.expect(!c.holds("1"));
    try testing.expect(!c.holds("nope"));
    try testing.expect(rowMatchesText(r, "context"));
    try testing.expect(rowMatchesText(r, "Right click"));
    try testing.expect(!rowMatchesText(r, "zzz"));
    // A schema value nobody curated is still offered, after the curated ones.
    const opts = try choices(testing.allocator, r, &.{ "copy", "brand-new", "ignore" });
    defer testing.allocator.free(opts);
    try testing.expectEqual(@as(usize, 6), opts.len);
    try testing.expectEqualStrings("Context menu", opts[0].label);
    try testing.expectEqualStrings("brand-new", opts[5].value);
    try testing.expectEqualStrings("brand-new", opts[5].label);
    const onoff = try choices(testing.allocator, rowFor("maximize").?, null);
    defer testing.allocator.free(onoff);
    try testing.expectEqual(@as(usize, 2), onoff.len);
    try testing.expectEqual(@as(usize, 8), all.len);
    try testing.expectEqual(PageId.appearance, all[0].id);
    try testing.expectEqual(PageId.advanced, all[all.len - 1].id);
}
