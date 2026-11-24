//! The GTK pane sidebar's pure half (T3557, Linux L10b;
//! docs/reference/pane-sidebar.md): what a row says, where the shared flags
//! are kept, and the line format the debug seam reports. No GTK imports, so
//! it runs in the none lane.
//!
//! The rules themselves are win32's pure modules, which carry the Mac's
//! (`PaneSidebarText`, `PaneSidebarSharedState.applyStart`):
//! `win32/pane_sidebar.zig` (the row's name and subtitle, the mode and the
//! column widths) and `win32/pane_sidebar_prefs.zig` (the persisted flags, the
//! forced start against the user's own choice). This file only puts them
//! together for GTK and names the Linux file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ps = @import("../win32/pane_sidebar.zig");
const prefs = @import("../win32/pane_sidebar_prefs.zig");

pub const Mode = ps.Mode;
pub const Prefs = prefs.Prefs;
pub const StartState = prefs.StartState;
pub const Start = prefs.Start;

/// Which mode a window's sidebar is in: hidden, the full panel, or the rail
/// (collapsed, or a window too narrow for the panel). A window that has not
/// been laid out yet (`window_w` 0) is not narrow: it would otherwise start
/// every new window in the rail for one frame.
pub fn mode(p: Prefs, window_w: i32) Mode {
    const w: f32 = if (window_w <= 0) ps.narrow_window_dip else @floatFromInt(window_w);
    return ps.mode(p.expanded, p.hidden, w);
}

/// Whether the toggle can expand at this width (the Mac's `canExpand`).
pub fn canExpand(window_w: i32) bool {
    if (window_w <= 0) return true;
    return ps.canExpand(@floatFromInt(window_w));
}

/// The sidebar card's width in logical pixels: the rail's card collapsed,
/// the panel at the shared width expanded (one card in both modes, Mac
/// `cardWidth`). GTK lays out in logical pixels, so these are the design's
/// DIP numbers unscaled.
pub fn cardWidth(m: Mode, p: Prefs) i32 {
    return @intFromFloat(@round(ps.cardDip(m, p.width_dip)));
}

/// The margin around the card (the design system's `lg`, the grid's gutter).
pub const card_margin: i32 = @intFromFloat(ps.rail_margin_dip);

/// The rail card's width (a row's pill around its icon).
pub fn railCardWidth() i32 {
    return @intFromFloat(@round(ps.rail_card_dip));
}

/// One pane as the sidebar sees it.
pub const Pane = struct {
    /// The terminal-set title (OSC 0/2), or a viewer's page title.
    title: ?[]const u8 = null,
    /// The name the user gave the pane (Change Pane Title), which outranks a
    /// banner's title.
    title_override: ?[]const u8 = null,
    pwd: ?[]const u8 = null,
    banner: ?[]const u8 = null,
    viewer: bool = false,
};

pub const Text = struct {
    label: []const u8,
    subtitle: ?[]const u8,
};

pub const TEXT_BUF_LEN: usize = 512;

/// A row's two lines (Mac `PaneSidebarText`): the banner's title when it has
/// one, else the pane's title (else its directory's name, else its kind); the
/// subtitle is the banner's first line when the banner has no title, else the
/// working directory with the home directory as `~` - and nothing when it
/// would only repeat the label.
pub fn text(p: Pane, home: ?[]const u8, label_buf: *[TEXT_BUF_LEN]u8, sub_buf: *[TEXT_BUF_LEN]u8) Text {
    const kind: []const u8 = if (p.viewer) "viewer" else "terminal";
    const raw = p.title_override orelse p.title;
    const label = ps.paneLabel(raw, p.pwd, kind, if (p.viewer) null else p.banner, p.title_override != null, label_buf);
    const sub: ?[]const u8 = if (p.viewer)
        null
    else if (ps.bannerSubtitle(p.banner, sub_buf)) |b|
        b
    else if (p.pwd) |d|
        // A pane titled by its own directory (the core reports the
        // directory as the title until a program sets one) would show the
        // same place twice - win32's rule.
        (if (d.len == 0 or ps.samePath(d, label)) null else ps.abbreviatePath(d, home, sub_buf))
    else
        null;
    return .{ .label = label, .subtitle = ps.distinct(sub, label) };
}

/// `<config root>/ghoztty/pane-sidebar[-debug]`: `$XDG_CONFIG_HOME`, else
/// `~/.config` - the session-layout manifest's root, so a test harness that
/// gives the app a private config dir gives this file one too. Debug builds
/// keep their own, so a dev window never changes how the release app opens.
pub fn prefsPath(alloc: Allocator, debug: bool, xdg_config_home: ?[]const u8, home: []const u8) Allocator.Error![]u8 {
    // A Linux path, spelled with `/` on every host so the none lane's test
    // reads the same on the Windows box (`std.fs.path.join` would use `\`).
    const name = if (debug) "pane-sidebar-debug" else "pane-sidebar";
    if (xdg_config_home) |x| if (x.len > 0) return std.fmt.allocPrint(alloc, "{s}/ghoztty/{s}", .{ x, name });
    return std.fmt.allocPrint(alloc, "{s}/.config/ghoztty/{s}", .{ home, name });
}

/// The persisted flags, or null (no file, unreadable, malformed). The file
/// is win32's format (`pane_sidebar_prefs.format`).
pub fn load(path: []const u8) ?Prefs {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var buf: [prefs.FORMAT_BUF_LEN]u8 = undefined;
    const n = f.readAll(&buf) catch return null;
    return prefs.parse(buf[0..n]);
}

/// Persist the flags. Best-effort: a preference is never worth an error.
pub fn save(path: []const u8, p: Prefs) void {
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    var buf: [prefs.FORMAT_BUF_LEN]u8 = undefined;
    f.writeAll(prefs.format(&buf, p)) catch {};
}

/// The debug seam's report of one window's sidebar, as JSON the acceptance
/// script reads (`pane-sidebar` seam, `IpcHandlers.zig`).
pub const Report = struct {
    mode: []const u8,
    expanded: bool,
    hidden: bool,
    can_expand: bool,
    visible: bool,
    width: i32,
    window_width: i32,
    /// The scope (T3558): every window's panes, not this window's.
    all_windows: bool = false,
    /// The shared search, and what this window's field holds and shows.
    search: []const u8 = "",
    search_shown: bool = false,
    search_field: []const u8 = "",
    scope_button_shown: bool = false,
    /// How many windows the all-windows list gathered.
    window_count: usize = 0,
    /// The header's caption.
    title: []const u8 = "",
    rows: []const Row,

    pub const Row = struct {
        /// A pane's id; a header's or rail tile's `window:<key>`,
        /// `project:<name>`, `ungrouped`.
        pane: []const u8,
        label: []const u8,
        subtitle: ?[]const u8,
        /// The label is on screen (the panel), not only a tooltip (the rail).
        label_shown: bool,
        tooltip: ?[]const u8,
        selected: bool,
        /// A pane stashed out of its window's layout (T3596).
        stashed: bool = false,
        /// `terminal` / `viewer` for a pane; `window`, `project`,
        /// `ungrouped` for a header; `tile` for a rail window tile.
        kind: []const u8,
        /// A header's windows or panes.
        count: usize = 0,
        folded: bool = false,
        /// Outline level (`pane_sidebar_all.Item.depth`).
        depth: u8 = 0,
        /// A window header's pill: `none`, `unemphasized`, `accent`.
        selection: []const u8 = "none",
    };
};

const testing = std.testing;

test "T3557: a row is named by its banner's title, else its title, else its directory" {
    var a: [TEXT_BUF_LEN]u8 = undefined;
    var b: [TEXT_BUF_LEN]u8 = undefined;

    // The banner hook's heading names the pane; the directory is the subtitle.
    var t = text(.{ .title = "vim", .pwd = "/home/ann/src", .banner = "## Fix the parser\n| a | b |" }, "/home/ann", &a, &b);
    try testing.expectEqualStrings("Fix the parser", t.label);
    try testing.expectEqualStrings("~/src", t.subtitle.?);

    // No banner: the title, and the directory under it.
    t = text(.{ .title = "make test", .pwd = "/tmp/work" }, "/home/ann", &a, &b);
    try testing.expectEqualStrings("make test", t.label);
    try testing.expectEqualStrings("/tmp/work", t.subtitle.?);

    // The ghost placeholder names nothing: the directory's name, and the
    // subtitle does not repeat it when it is the whole of it.
    t = text(.{ .title = "\u{1F47B}", .pwd = "/srv" }, null, &a, &b);
    try testing.expectEqualStrings("srv", t.label);

    // Titled by its own directory: the path once, no subtitle repeating it.
    t = text(.{ .title = "/home/ann/src", .pwd = "/home/ann/src/" }, "/home/ann", &a, &b);
    try testing.expectEqualStrings("/home/ann/src", t.label);
    try testing.expect(t.subtitle == null);

    // A banner with no title (a bold label) leaves the title in place and
    // gives the row its first line as the subtitle.
    t = text(.{ .title = "zsh", .pwd = "/home/ann", .banner = "**Goal:** ship it\n- [x] a" }, "/home/ann", &a, &b);
    try testing.expectEqualStrings("zsh", t.label);
    try testing.expectEqualStrings("Goal: ship it", t.subtitle.?);

    // The user's own name outranks the banner's title.
    t = text(.{ .title = "zsh", .title_override = "build box", .banner = "## Task" }, null, &a, &b);
    try testing.expectEqualStrings("build box", t.label);

    // A viewer has no banner and no directory line.
    t = text(.{ .title = "README.md", .pwd = "/x", .viewer = true, .banner = "## ignored" }, null, &a, &b);
    try testing.expectEqualStrings("README.md", t.label);
    try testing.expect(t.subtitle == null);

    // Nothing at all: the pane's kind.
    t = text(.{}, null, &a, &b);
    try testing.expectEqualStrings("terminal", t.label);
    try testing.expect(t.subtitle == null);
}

test "T3557: the mode follows the shared flags, and a narrow window gets the rail" {
    try testing.expectEqual(Mode.expanded, mode(.{ .expanded = true }, 1000));
    try testing.expectEqual(Mode.mini, mode(.{ .expanded = false }, 1000));
    try testing.expectEqual(Mode.hidden, mode(.{ .expanded = true, .hidden = true }, 1000));
    // Under 720: the rail whatever the flag says, and the toggle cannot expand.
    try testing.expectEqual(Mode.mini, mode(.{ .expanded = true }, 500));
    try testing.expect(!canExpand(500));
    try testing.expect(canExpand(800));
    // Not laid out yet is not narrow.
    try testing.expectEqual(Mode.expanded, mode(.{ .expanded = true }, 0));
    // The rail is narrower than the panel; the panel takes the shared width.
    try testing.expect(cardWidth(.mini, .{}) < cardWidth(.expanded, .{}));
    try testing.expectEqual(@as(i32, 300), cardWidth(.expanded, .{ .width_dip = 300 }));
    try testing.expectEqual(railCardWidth(), cardWidth(.mini, .{}));
    try testing.expectEqual(@as(i32, 0), cardWidth(.hidden, .{}));
}

test "T3557: the flags live under the config root, debug apart from release" {
    const alloc = testing.allocator;
    const a = try prefsPath(alloc, true, "/x/cfg", "/home/ann");
    defer alloc.free(a);
    try testing.expectEqualStrings("/x/cfg/ghoztty/pane-sidebar-debug", a);
    const b = try prefsPath(alloc, false, null, "/home/ann");
    defer alloc.free(b);
    try testing.expectEqualStrings("/home/ann/.config/ghoztty/pane-sidebar", b);
    const c = try prefsPath(alloc, false, "", "/home/ann");
    defer alloc.free(c);
    try testing.expectEqualStrings("/home/ann/.config/ghoztty/pane-sidebar", c);
}

test "T3557: a forced start is not written over the user's own flags" {
    var live: Prefs = .{ .expanded = false, .hidden = false };
    var st = StartState.init(live);
    try testing.expect(st.apply(&live, .expanded));
    try testing.expect(live.expanded);
    // The file still keeps the user's collapsed choice.
    try testing.expect(!st.toSave(live).expanded);
    // A reload with the same value changes nothing (the user's toggles stand).
    st.userSet(&live, false, true);
    try testing.expect(!st.apply(&live, .expanded));
    try testing.expect(live.hidden);
}
