//! The pane sidebar on Windows (T1828; Mac 597a193cc, `PaneSidebarView`,
//! `docs/design/pane-sidebar.md`): a child of the window, left of the split
//! grid, listing every pane of the active tab — the panes in the grid with the
//! focused one selected, then the stashed ones (T1827).
//!
//! Expanded, it is a flat panel down the window's side: one more column of
//! the window, on the terminal background lifted by the card wash, separated
//! from the grid by a divider-colored rule. Collapsed, it is the raised card
//! the banner and the viewer side panel use, as the mini rail — one tile per
//! pane, each its row without the text: the same pill, the same kind glyph
//! in the pane's hue at the same place (T2279, Mac 75dc046e3). A busy pane's
//! row or tile carries the same sheen. Hidden (`toggle_pane_sidebar`), it
//! takes no space.
//!
//! Clicking a row focuses that pane, or restores it when it is stashed. A
//! row's hover button stashes a grid pane or restores a stashed one. One
//! toggle switches collapsed and expanded (T2289, Mac e77422577/dc2bbab6b):
//! the header's first item, on the same pixels in both modes, and off - with
//! a tooltip that says why - in a window too narrow for the panel. There is
//! no pin and no hover-open: the rail never grows under the pointer.
//! Everything about modes, widths, text and geometry is `pane_sidebar.zig`,
//! which is unit-tested without a window; this file only paints what that
//! decides and routes the clicks back to `Window`.
//!
//! Every tile, row, row button and the toggle carries a tooltip (Mac
//! `.help`); a tile's names its pane, since the rail shows only its glyph.
//! The wording is `pane_sidebar_tips.zig`.
//!
//! The roster is rebuilt only when what it shows changed — `refresh` hashes
//! the panes, their titles, banners, states and the selection first — because
//! it is asked on every layout pass, and a divider drag is a layout pass per
//! mouse move.

const PaneSidebar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const pane_sidebar = @import("pane_sidebar.zig");
const outline = @import("pane_sidebar_outline.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const tips = @import("pane_sidebar_tips.zig");
const sidebar_prefs = @import("pane_sidebar_prefs.zig");
const shared_mod = @import("pane_sidebar_shared.zig");
const row_menu = @import("pane_sidebar_menu.zig");
const add_rules = @import("pane_sidebar_add.zig");
const rename_rules = @import("pane_sidebar_rename.zig");
const search_field = @import("pane_sidebar_search.zig");
const scroll_mod = @import("pane_sidebar_scroll.zig");
const motion = @import("pane_sidebar_motion.zig");
const reorder = @import("pane_sidebar_reorder.zig");
const pane_sidebar_order = @import("pane_sidebar_order.zig");
const window_order = @import("pane_sidebar_window_order.zig");
const cross_drop = @import("pane_sidebar_cross_drop.zig");
const transition = @import("pane_sidebar_transition.zig");
const xf = @import("pane_sidebar_xfade.zig");
const Dib32 = @import("dib32.zig");
const App = @import("App.zig");
const toc = @import("viewer_toc_layout.zig");
const color_math = @import("color_math.zig");
const pane_hue = @import("pane_hue.zig");
const chrome_theme = @import("chrome_theme.zig");
const system_colors = @import("system_colors.zig");
const banner_card = @import("banner_card.zig");
const type_ramp = @import("type_ramp.zig");
const list_selection = @import("list_selection.zig");
const icon_button = @import("icon_button.zig");
const icon_button_paint = @import("icon_button_paint.zig");
const pane_elevation = @import("pane_elevation.zig");
const pane_drop = @import("pane_drop.zig");
const drop_highlight = @import("drop_highlight.zig");
const PaneView = @import("PaneView.zig");
const Window = @import("Window.zig");
const PaneDesk = @import("PaneDesk.zig");
const gutter_bar = @import("gutter_bar.zig");
const gutter_bar_dc = @import("gutter_bar_dc.zig");
const busy_light = @import("busy_light.zig");

const log = std.log.scoped(.pane_sidebar);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyPaneSidebar");

/// Timer ids. (1 and 2 were the hover-open card's, retired with it in T2289.)
/// The motion clock (T1843), while something on the column moves.
const TIMER_ANIM: usize = 3;
/// A list transition's frame clock (T1880).
const TIMER_XFADE: usize = 4;
/// The column collapsing or expanding (T2291).
const TIMER_COLUMN: usize = 5;
/// Rows sliding to make room for a dragged pane, or the held row gliding to
/// where it landed (T2304).
const TIMER_REORDER: usize = 6;

/// Tooltip tool ids: the toggle, then one per item, then one per row button.
const tool_toggle: usize = 0;
fn toolItem(i: usize) usize {
    return 1 + i;
}
fn toolButton(i: usize) usize {
    return 1 + pane_sidebar.max_items + i;
}
fn toolHead(k: usize) usize {
    return 1 + 2 * pane_sidebar.max_items + k;
}
const tool_scope: usize = 1 + 2 * pane_sidebar.max_items + pane_sidebar.max_heads;
const tool_search: usize = tool_scope + 1;
const tool_search_clear: usize = tool_scope + 2;
/// A row's hover x (T2280), after every fixed tool.
fn toolClose(i: usize) usize {
    return tool_search_clear + 1 + i;
}
/// A header's hover x (T2298), after the rows'.
fn toolHeadClose(k: usize) usize {
    return toolClose(pane_sidebar.max_items) + k;
}
/// A header's hover + (T2323), after the x's; then the header's +.
fn toolHeadAdd(k: usize) usize {
    return toolHeadClose(pane_sidebar.max_heads) + k;
}
const tool_add: usize = toolHeadAdd(pane_sidebar.max_heads);
/// The rail's + in this window's header slot (T2324).
const tool_rail_add: usize = tool_add + 1;
/// A row's hover pencil (T2339), then a header's.
fn toolRowRename(i: usize) usize {
    return tool_rail_add + 1 + i;
}
fn toolHeadRename(k: usize) usize {
    return toolRowRename(pane_sidebar.max_items) + k;
}

/// What new windows start from: the most recently chosen expanded and hidden
/// flags, the way a Finder window's sidebar does (Mac `rememberForNewWindows`),
/// and the panel width - one preference shared by every window (Mac
/// `PaneSidebarWidth`, T1846). Loaded from `pane_sidebar_prefs` before the
/// first window opens and written back on every user change, so it survives
/// a restart (T1847).
pub var remembered: sidebar_prefs.Prefs = .{};
var remembered_loaded = false;

/// Read the persisted defaults into `remembered`, once per process. Called
/// by `Window.init` before it seeds a window from them.
pub fn loadRemembered(alloc: std.mem.Allocator) void {
    if (remembered_loaded) return;
    remembered_loaded = true;
    if (sidebar_prefs.load(alloc)) |p| remembered = p;
    // The all-windows list's order (T2337), kept with the shared state.
    if (window_order.load(alloc)) |text| {
        defer alloc.free(text);
        var keys: [window_order.max_keys][]const u8 = undefined;
        const n = window_order.parse(text, &keys);
        _ = shared.setWindowOrder(alloc, keys[0..n]);
    }
}

/// Write `remembered` back. Best-effort, like every chrome preference.
pub fn saveRemembered(alloc: std.mem.Allocator) void {
    sidebar_prefs.save(alloc, remembered);
}

/// The rest of the sidebar every window shares (T2336, Mac
/// `PaneSidebarSharedState`): the all-windows scope, its search, the folds
/// and the all-windows list's scroll. Each sidebar draws its own copy of it
/// (`takeShared`) - the window in use takes a change as it makes it, every other
/// window when it is next activated (`catchUp`).
pub var shared: shared_mod.Shared = .{};

/// A window group of the outline: one tab of one top-level window (a Mac
/// window is a tab here - see `pane_sidebar_outline.zig`).
const Group = struct {
    window: *Window,
    tab: usize,
    /// The tab's stable identity, hashed - the fold key, and how a click
    /// finds the tab again after a reorder.
    key: u64,
    /// Its key in the all-windows list's order (T2337): `window:<tab id>`,
    /// and its project's `project:<name>` (empty for a lone window).
    wkey: window_order.Key = .{},
    pkey: window_order.Key = .{},
    /// The header's text: the worktree inside a project, else the name.
    label: []u16,
    /// The project it is grouped under, as shown (upper-cased), or empty.
    project: []u16,
    project_key: u64,
    /// How many windows the project holds (on its first window only).
    project_size: usize,
    panes: usize,
    own: bool,
    /// The top-level has other tabs: "This Tab" rather than "This Window".
    tabbed: bool,
};

/// Fluent / MDL2 codepoints (the same faces `icon_button_paint` probes).
const glyph_terminal: u16 = 0xE756; // CommandPrompt
const glyph_document: u16 = 0xE8A5; // Document
const glyph_globe: u16 = 0xE774; // Globe
const glyph_photo: u16 = 0xE91B; // Photo
const glyph_code: u16 = 0xE943; // Code
// The collapse/expand toggle (Mac's `.sidebar` symbol, a window with its
// sidebar): the open pane offered by the rail, the close pane by the panel -
// the Fluent pair Windows' own navigation panes use.
const glyph_open_pane: u16 = 0xE8A0; // OpenPane: "expand the sidebar"
const glyph_close_pane: u16 = 0xE89F; // ClosePane: "collapse it to icons"
const glyph_stash: u16 = 0xE921; // ChromeMinimize: "put this away"
const glyph_restore: u16 = 0xE7A7; // Undo: "bring it back"
const glyph_windows: u16 = 0xE7C4; // TaskView: "every window"
const glyph_close: u16 = 0xE711; // Cancel: a row's x, the search's clear
const glyph_add: u16 = 0xE710; // Add: the header's and a header's + (T2323)
const glyph_rename: u16 = 0xE70F; // Edit: the rename pencil (T2339)
const glyph_search: u16 = 0xE721; // Search: the field's magnifier (T1877)
const glyph_app_window: u16 = 0xECAA; // AppIconDefault: a window head's icon (Mac `macwindow`, T2340)
const glyph_chevron_down: u16 = 0xE70D;
const glyph_chevron_right: u16 = 0xE76C;

const FadeSlot = struct { pane: *const PaneView, fade: motion.Fade };

/// One row's slide, by pane: a roster refresh mid-drag rebuilds the entries.
const RowShift = struct { pane: *const PaneView, tween: reorder.Tween };

/// A pane dragged over this sidebar (T2304, Mac `PaneSidebarShift` /
/// `PaneSidebarRowDrag`).
const DragMotion = struct {
    pane: *const PaneView,
    /// Where it is and would land in this sidebar's sequence; null while it
    /// would land elsewhere (the rows stay put) and once the drag ended.
    slide: ?reorder.Slide = null,
    shifts: [pane_sidebar.max_items]RowShift = undefined,
    shift_count: usize = 0,
    /// The tray's header - its hairline and caption - slides with the rows.
    header: reorder.Tween = .{},
    /// A drag of this sidebar's own row: the row follows the pointer.
    held: ?Held = null,
};

/// The dragged row, held by the pointer (Mac `PaneSidebarRowDrag`): how far
/// the pointer has travelled since the press, where the row was last drawn,
/// and - let go - the glide from there to where it landed.
const Held = struct {
    press_y: i32,
    dy: i32 = 0,
    drawn_top: ?i32 = null,
    settle: ?Settle = null,

    const Settle = struct { from: i32, start_ms: u64 };
};

/// A window row or project header held by the pointer among its siblings in
/// the all-windows list (T2337, Mac `PaneSidebarItemDrag`).
const ItemDrag = struct {
    key: window_order.Key,
    kind: pane_sidebar.HeadKind,
    /// The list it moves in, itself included, in the list's order: its
    /// project's windows, or the top level (groups and lone windows).
    siblings: [pane_sidebar.max_heads]window_order.Key = undefined,
    count: usize = 0,
    source: usize = 0,
    /// The index it would land at, of the siblings without it.
    target: usize = 0,
    /// The pointer's client y, where in the item it was grabbed, and the
    /// item's top then: a drag folds the list up from under it, and the held
    /// item stays under the pointer (`window_order.clamp`).
    pointer: i32,
    grab: i32,
    grabbed_top: i32,
    /// Where the held item's top is drawn.
    top: i32,
    /// Each sibling's slide, by index.
    shifts: [pane_sidebar.max_heads]reorder.Tween = [_]reorder.Tween{.{}} ** pane_sidebar.max_heads,
    /// The folds the drag took, put back once it lands.
    folds_before: ?shared_mod.KeySet = null,
    unfolded_before: ?shared_mod.KeySet = null,
    /// Let go: gliding from where it was drawn to its laid-out place.
    settle: ?Held.Settle = null,

    /// A window drag (T2338, Mac `PaneSidebarCrossDrop`): `siblings` holds
    /// the whole list as rows - each group's header, its windows, the lone
    /// windows - every row slides on its own, and the window may land in any
    /// group or none. A group drag still moves among its siblings only.
    cross: bool = false,
    /// Per row: its group's key (empty for a lone window), and whether it is
    /// that group's header.
    row_pkey: [pane_sidebar.max_heads]window_order.Key = undefined,
    row_header: std.StaticBitSet(pane_sidebar.max_heads) = .initEmpty(),
    /// How far the others slide: the window's row and the gap after it.
    pitch: i32 = 0,
    /// Where a window drag would land.
    dest: ?CrossDest = null,
    /// The group header outlined while the drop would join a group the
    /// window is not in (Mac `PaneSidebarJoinHighlight`), fading in, and the
    /// one fading out - by row.
    join_in: ?JoinFade = null,
    join_out: ?JoinFade = null,

    const CrossDest = union(enum) {
        /// Into the group row `row` names, at `index` among its windows.
        group: struct { row: usize, index: usize },
        top_level: usize,
    };
    const JoinFade = struct { row: usize, start_ms: u64 };

    /// Row `j`'s group name, or null for a lone window.
    fn rowProject(self: *const ItemDrag, j: usize) ?[]const u8 {
        const k = self.row_pkey[j].slice();
        if (k.len == 0) return null;
        return k[window_order.project_prefix.len..];
    }

    /// The dragged window's group name now, or null.
    fn ownProject(self: *const ItemDrag) ?[]const u8 {
        return self.rowProject(self.source);
    }

    /// The group a destination lands in, or null at the top level.
    fn destProject(self: *const ItemDrag, dest: CrossDest) ?[]const u8 {
        return switch (dest) {
            .group => |g| self.rowProject(g.row),
            .top_level => null,
        };
    }
};

/// The join outline's fade (Mac `PaneSidebarJoinHighlight`: 0.12s ease-out).
const join_fade_ms: u64 = 120;

/// Working, as anything that shows it is concerned (T2279, Mac
/// `PaneView.isWorking`, 919fba868): its activity state says busy (the agent
/// hooks), or a progress report (OSC 9;4) is in force - what lights the
/// pane's border (T1899, `Window.busyReportFor`). Mac read only the activity
/// state before, and a working Claude pane's border moved while its icon sat
/// still.
fn isWorking(v: *PaneView, now_ms: i64) bool {
    const s = v.surface() orelse return false;
    if (s.activity_state == .busy) return true;
    const r = s.liveProgress(now_ms) orelse return false;
    return busy_light.shapeFor(r) != null;
}

const Entry = struct {
    pane: *PaneView,
    /// The window and tab the pane lives in: this sidebar's own, or - in the
    /// all-windows scope (T1829) - any. Pointers to ask about, never to use
    /// unchecked: another window can close between a refresh and a click.
    window: *Window,
    tab: usize,
    /// Its window group in the outline (0 in the single roster), and whether
    /// that group is THIS window's active tab.
    group: u16 = 0,
    own: bool = true,
    section: pane_sidebar.Section,
    title: []u16,
    subtitle: []u16,
    icon: u16,
    /// Its place in its tab's tree, stashed panes included: what its hue is
    /// spaced by (T2278, `pane_hue`), so a reorder of the list recolors
    /// nothing.
    hue: u16 = 0,
    /// Working, as its border shows it (`isWorking`): its row sheens.
    busy: bool,
    /// The bell rang and the pane has not been looked at since.
    bell: bool,
    selected: bool,
};

/// What a rename in place edits (T2339): a pane - asked about by address
/// only, never followed until it is found in a live window again - or a
/// window group by its tab's identity, or a project group by its name's key.
const RenameTarget = union(enum) {
    pane: *PaneView,
    window: u64,
    project: u64,
};

/// A name being edited in place (T2339, Mac `PaneSidebarRenameField`).
const Rename = struct {
    target: RenameTarget,
    field: search_field.Field = .{},
    /// What the item showed when the field opened, as UTF-8: an unchanged
    /// commit is measured against it, and a project's windows are found by it.
    initial: [initial_cap]u8 = undefined,
    initial_len: usize = 0,
    /// Where the field's text was last painted, in client pixels, and in
    /// which font: a press inside it puts the caret down rather than
    /// committing, and lands by the same measure the paint used.
    box: pane_sidebar.Rect = .{},
    font: ?*anyopaque = null,

    const initial_cap = search_field.cap * 3;

    fn initialText(self: *const Rename) []const u8 {
        return self.initial[0..self.initial_len];
    }
};

hwnd: w32.HWND,
window: *Window,
alloc: Allocator,

entries: std.ArrayListUnmanaged(Entry) = .{},
signature: u64 = 0,

// The all-windows scope (T1829). Not persisted, as Mac's is not: the switch,
// and what is folded, belong to one look at every window. This and the
// search and folds below are this sidebar's drawn copy of `shared` (T2336),
// as of shared change `seen_gen`.
all_windows: bool = false,
seen_gen: u64 = 0,
/// One per window group, in outline order.
groups: std.ArrayListUnmanaged(Group) = .{},
/// The panel's lines (`pane_sidebar_outline.buildLines`).
lines: std.ArrayListUnmanaged(pane_sidebar.Line) = .{},
/// Window groups (by tab identity) showing their panes in the all-windows
/// list (T2336, Mac `unfoldedWindows`): absolute, so every window's list
/// folds alike. The scope opens holding only the group it was turned on
/// from; a tab switch later never unfolds anything, or the list would jump
/// under the pointer (Mac 321e61d7c). Forgotten when the scope is left.
unfolded: shared_mod.KeySet = .{},
/// Window groups folded to their header in their own "this window" list,
/// which starts open (Mac `foldedThisWindowLists`).
folded_this: shared_mod.KeySet = .{},
/// Folded projects (by name). These outlive the scope, as Mac's
/// `foldedProjects` do.
folded_projects: shared_mod.KeySet = .{},
/// Another window's pane row just clicked in this all-windows list (Mac
/// `clickedPane`): drawn selected here while that window comes forward, until
/// this window is activated again and shows its own selection. Compared,
/// never dereferenced.
clicked: ?*const PaneView = null,
/// How many windows the scope lists (every tab of every window, whatever
/// the search) - the ALL WINDOWS caption's count.
window_count: usize = 0,
/// The all-windows search (T1877, Mac `PaneSidebarFilter`): the field's text
/// and caret, and whether the column holds the keyboard for it. Like the
/// scope, never persisted; turning the scope off empties it.
search: search_field.Field = .{},
search_focus: bool = false,
/// The name being edited in place (T2339): while set, the column's keyboard
/// is the field's, not the search's.
rename: ?Rename = null,

// Scrolling (T1878, `pane_sidebar_scroll`): the wanted offset, clamped by
// every layout, the wheel's carried remainder, a thumb drag in progress, and
// the pane whose row was last brought into view (a NEW selection reveals; the
// same one never fights the user's own scrolling).
scroll: i32 = 0,
wheel: scroll_mod.Wheel = .{},
thumb_drag: ?struct { grab: i32 } = null,
revealed: ?*PaneView = null,
/// The pane this sidebar last handed the hover tint to (T2278), so a hover
/// change clears only its own (`syncHoverTint`).
tint_pane: ?*const PaneView = null,

mode: pane_sidebar.Mode = .hidden,
/// `Window.paneSidebarReachPx()` at the last `place` (T1900).
reach: i32 = 0,
/// `Window.paneSidebarCanExpand()` at the last `place` (T2289): false in a
/// window too narrow for the panel, where the rail's toggle is off.
can_expand: bool = true,
scale: f32 = 1.0,
hover: pane_sidebar.Hit = .none,
pressed: pane_sidebar.Hit = .none,
tracking: bool = false,
/// Where the held press went down, in the pressed surface's client
/// coordinates: a press on a row that travels past the drag threshold hands
/// the pane to the window's drag (T1844).
press_x: i32 = 0,
press_y: i32 = 0,
/// Alt was down when the held press went down (T1845's Alt-click swap).
press_alt: bool = false,
/// An edge drag in progress (T1846): the width it measures from
/// (`pane_sidebar.edgeStartDip`) and the screen x it went down at. Screen,
/// not client, so the measure survives the rail turning into the panel
/// under the pointer. `gutter` says it went down in the window's gutter
/// beside the expanded panel (the elevated style's grip, T2265), whose bar
/// the window paints. Null otherwise.
edge: ?struct { start_dip: f32, start_x: i32, gutter: bool = false } = null,
/// The pointer is over the edge band (T2265): its accent bar shows at half
/// strength.
edge_hover: bool = false,
/// The edge bar last painted, for the debug-log oracle.
edge_bar_logged: ?gutter_bar.Strength = null,
/// A pane drag is live somewhere (T1844): the empty tray's well brightens
/// and says "Drop to stash" (T2276; it is there at rest too).
drag_active: bool = false,
/// What the rows do for a pane dragged over this sidebar (T2304): slide to
/// make room, and - a row dragged from here - follow the pointer.
drag: ?DragMotion = null,
/// The row a paint leaves out: lifted out of the list by a drag (T2304).
paint_lifted: ?usize = null,
reorder_armed: bool = false,
/// A window row or project header dragged up or down the all-windows list
/// (T2337), and what a paint leaves out of the list for it: the dragged
/// item's header and rows, drawn lifted instead.
item_drag: ?ItemDrag = null,
/// The join outline has been logged once for this drag (T2338's oracle).
join_logged: bool = false,
lifted_heads: std.StaticBitSet(pane_sidebar.max_heads) = .initEmpty(),
lifted_items: std.StaticBitSet(pane_sidebar.max_items) = .initEmpty(),

// Tooltips: one control. A tile's text names its pane, so it lives here (a
// tool keeps a pointer to its text); every other tip is a constant.
tip: ?w32.HWND = null,
tip_text: [pane_sidebar.max_items][tips.tip_cap]u16 = undefined,
tip_items: usize = 0,
tip_heads: usize = 0,
/// Each header x's tip, kept alive for the tooltip (a project's names its
/// window count).
head_tip_text: [pane_sidebar.max_heads][40:0]u16 = undefined,
/// A header +'s tip ("New window in <project>", T2323), per head.
head_add_tip_text: [pane_sidebar.max_heads][80:0]u16 = undefined,
tip_log: [256]u8 = undefined,
tip_log_len: usize = 0,

title_font: ?*anyopaque = null,
/// A window header's name: the body size at the weight a sidebar gives a
/// group (Mac's 12 semibold).
title_bold_font: ?*anyopaque = null,
caption_font: ?*anyopaque = null,
caption_bold_font: ?*anyopaque = null,

font_scale: f32 = 0,
metrics: pane_sidebar.TextMetrics = .{ .title_h = 19, .caption_h = 16 },

// Motion (T1843). Each paint counts the marks it drew into `paint_marks`
// against one clock reading, and leaves the tally in `marks`: the motion
// timer runs while the last paint drew something that moves, and stops
// itself on the first tick after it did not.
paint_marks: motion.Marks = .{},
paint_ms: u64 = 0,
paint_motion: bool = true,
marks: motion.Marks = .{},
anim_armed: bool = false,
/// Where the moving pills were drawn (T1925): the paint fills `paint_dirty`
/// and leaves it in `dirty`, and a motion frame invalidates those alone.
paint_dirty: motion.Dirty = .{},
dirty: motion.Dirty = .{},
/// What a motion run cost (T1925), logged when its clock stops: frames
/// painted, and the pixels they painted against the column's - the measure
/// of whether a frame repaints a pill or the whole sidebar.
motion_frames: u64 = 0,
motion_px: u64 = 0,
motion_client_px: u64 = 0,
/// Each pane's sheen fading in or out (T2279, Mac `busyFade`), by pane: kept
/// across roster refreshes, which rebuild the entries. A slot whose sheen has
/// finished fading out is free.
fades: [pane_sidebar.max_items]FadeSlot = undefined,
fade_count: usize = 0,
/// When a motion tick last re-read the roster, so a progress report that
/// expired without a "done" stops its row's sheen (`onMotionTick`).
busy_poll_ms: u64 = 0,
/// The list transition running on the panel (T1880): the scope slide or a
/// fold, composed from a picture of the frame before it (`xf`).
xfade: ?xf.Xfade = null,
/// The column collapsing or expanding (T2291): its width animates while the
/// rail and the panel crossfade in it. Meanwhile the layout is the new
/// mode's at the width it goes to, whatever the column is drawn at.
column: ?xf.Column = null,
/// Paint the material alone - no header, no rows: the backdrop a transition
/// lays the moving lists over.
paint_bare: bool = false,
/// The last roster tally logged (busy, bell), so the log says when it moved
/// rather than on every refresh.
logged_marks: [2]usize = .{ 0, 0 },
/// The hash of the last row text logged (`logText`), for the same reason.
logged_text: u64 = 0,

/// The card material behind the rail and the expanded list (one card in
/// both modes, T2290), cached like the TOC card's.
card: CardCache = .{},
/// The desk generation the window last told this sidebar about.
last_desk_gen: u32 = 0,

const CardCache = struct {
    dc: ?w32.HDC = null,
    bmp: ?*anyopaque = null,
    w: i32 = 0,
    h: i32 = 0,
    bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    scale: f32 = 0,
    /// The desk generation it was composited over (T1850); 0 = none, the
    /// flat style's terminal background.
    desk_gen: u32 = 0,
    /// The card rect it was built for.
    insets: [4]i32 = .{ 0, 0, 0, 0 },
    material: Material = .card,

    fn release(self: *CardCache) void {
        if (self.dc) |dc| _ = w32.DeleteDC(dc);
        if (self.bmp) |b| _ = w32.DeleteObject(b);
        self.* = .{};
    }
};

var class_registered: bool = false;

fn registerOne(hinstance: ?w32.HINSTANCE, name: [*:0]const u16) bool {
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (design system §5c): the panel's rule and
        // the cards are drawn against the window's own bounds.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // every pixel painted in WM_PAINT
        .lpszMenuName = null,
        .lpszClassName = name,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("pane sidebar class registration failed", .{});
        return false;
    }
    return true;
}

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (!class_registered) class_registered = registerOne(hinstance, CLASS_NAME);
}

/// Create the sidebar as a hidden child of `parent`. Null when the window
/// cannot be created: the window then lays its grid out without a column,
/// which is the pre-T1828 world rather than a crash.
pub fn create(alloc: Allocator, window: *Window, parent: w32.HWND) ?*PaneSidebar {
    const hinstance = w32.GetModuleHandleW(null);
    registerClass(hinstance);
    if (!class_registered) return null;
    const self = alloc.create(PaneSidebar) catch return null;
    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        parent,
        null,
        hinstance,
        null,
    ) orelse {
        alloc.destroy(self);
        return null;
    };
    self.* = .{ .hwnd = hwnd, .window = window, .alloc = alloc };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    // A new window's sidebar is the one every window shows (T2336).
    self.takeShared();
    return self;
}

// -------------------------------------------------------------------------
// The state every window shares (T2336)
// -------------------------------------------------------------------------

/// Draw the shared state from now on: copy it into this sidebar.
fn takeShared(self: *PaneSidebar) void {
    self.all_windows = shared.all_windows;
    self.search = shared.search;
    shared_mod.copySet(self.alloc, &self.unfolded, &shared.unfolded);
    shared_mod.copySet(self.alloc, &self.folded_this, &shared.folded_this);
    shared_mod.copySet(self.alloc, &self.folded_projects, &shared.folded_projects);
    self.seen_gen = shared.gen;
}

/// This sidebar's window was just activated (Mac `catchUp`, from
/// `windowDidBecomeKey`): take whatever another window changed meanwhile,
/// show this window's own selection again, and take up the all-windows
/// list's scroll where the last list scrolled left it. Cheap when nothing
/// changed.
pub fn catchUp(self: *PaneSidebar) void {
    const behind = shared_mod.needsCatchUp(self.seen_gen, &shared);
    const clicked = self.clicked != null;
    self.clicked = null;
    if (behind) {
        const scope_was = self.all_windows;
        self.takeShared();
        if (self.search_focus and !self.searchShown()) self.releaseSearchFocus();
        if (scope_was != self.all_windows) {
            self.hover = .none;
            self.syncHoverTint();
        }
        log.info("pane sidebar catch up window={d} all_windows={} search={d} unfolded={d} folded_this={d} projects={d} gen={d}", .{
            if (self.window.hwnd) |h| @intFromPtr(h) else 0,
            self.all_windows,
            self.search.len,
            self.unfolded.count(),
            self.folded_this.count(),
            self.folded_projects.count(),
            self.seen_gen,
        });
    }
    if (behind or clicked) {
        self.signature = 0;
        self.refresh();
    }
    self.takeScroll();
}

/// A change made here is the shared one: take it back as this sidebar's own
/// copy so this window does not count itself behind.
fn published(self: *PaneSidebar) void {
    self.takeShared();
}

/// The all-windows list appears or its window is activated: scroll to where
/// the last list scrolled in this layout (Mac `PaneSidebarScrollSync`). Never
/// called mid-scroll, so nothing moves under the pointer.
fn takeScroll(self: *PaneSidebar) void {
    if (!self.all_windows or self.mode == .hidden) return;
    const want = shared.scrollFor(shared_mod.Surface.of(self.mode == .expanded)) orelse return;
    if (want == self.scroll) return;
    self.scrollTo(want);
    log.info("pane sidebar scroll synced window={d} offset={d}", .{ if (self.window.hwnd) |h| @intFromPtr(h) else 0, self.scroll });
}

pub fn destroy(self: *PaneSidebar) void {
    // A drag cut short by the window closing still gives the folds back.
    self.finishItemDrag();
    // Let go of the tint this sidebar handed out (T2278).
    self.hover = .none;
    self.syncHoverTint();
    // Clear the back-pointer FIRST: DestroyWindow delivers messages
    // synchronously and they must not find a half-dead object.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    if (self.tip) |t| _ = w32.DestroyWindow(t);
    _ = w32.DestroyWindow(self.hwnd);
    self.clearEntries();
    self.entries.deinit(self.alloc);
    self.clearGroups();
    self.groups.deinit(self.alloc);
    self.lines.deinit(self.alloc);
    self.unfolded.deinit(self.alloc);
    self.folded_this.deinit(self.alloc);
    self.folded_projects.deinit(self.alloc);
    if (self.xfade) |*v| v.deinit();
    self.xfade = null;
    if (self.column) |*v| v.deinit();
    self.column = null;
    self.card.release();
    self.releaseFonts();
    self.alloc.destroy(self);
}

fn fromHwnd(hwnd: w32.HWND) ?*PaneSidebar {
    const v = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

// -------------------------------------------------------------------------
// State pushed by the window
// -------------------------------------------------------------------------

/// Place the column at `rect` (window client coordinates) in `mode`, hiding
/// it when there is nothing to show.
pub fn place(self: *PaneSidebar, target: w32.RECT, mode: pane_sidebar.Mode, scale: f32) void {
    const changed = mode != self.mode or scale != self.scale;
    // Collapsing or expanding glides (T2291): picture the column as it is
    // shown, before the mode it paints in changes.
    const flipping = changed and scale == self.scale and
        self.mode != .hidden and mode != .hidden;
    const leaving: ?xf.Column = if (flipping) self.snapshotColumn() else null;
    if (changed and !flipping) self.dropColumn();
    self.mode = mode;
    self.scale = scale;
    var rect = target;
    if (leaving) |c| self.startColumn(c, rect.right - rect.left);
    if (self.column) |*c| {
        // Placed again mid-glide (a layout pass, a window resize): it goes to
        // the width the window gives it now, from where it is drawn.
        c.to_w = rect.right - rect.left;
        if (c.h != rect.bottom - rect.top) {
            self.dropColumn();
        } else rect.right = rect.left + c.widthAt(w32.GetTickCount64());
    }
    // T1877: a field that is no longer on screen gives the caret back, and a
    // query filters the panel but never the rail - a mode change re-asks.
    if (self.search_focus and !self.searchShown()) self.releaseSearchFocus();
    // T2339: a rename field lives in the panel's rows; the rail has none.
    if (self.rename != null and mode != .expanded) self.endRename(false, "collapsed");
    if (changed and !self.search.isEmpty()) self.refresh();
    if (mode == .hidden or rect.right <= rect.left or rect.bottom <= rect.top) {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        return;
    }
    var cur: w32.RECT = undefined;
    const moved = blk: {
        if (w32.GetWindowRect(self.hwnd, &cur) == 0) break :blk true;
        var tl = w32.POINT{ .x = cur.left, .y = cur.top };
        const parent = w32.GetParent(self.hwnd) orelse break :blk true;
        _ = w32.ScreenToClient(parent, &tl);
        break :blk tl.x != rect.left or tl.y != rect.top or
            cur.right - cur.left != rect.right - rect.left or
            cur.bottom - cur.top != rect.bottom - rect.top;
    };
    if (moved or w32.IsWindowVisible(self.hwnd) == 0) {
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            w32.SWP_NOZORDER | w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW,
        );
    }
    // A new shape (the rail expanded into the panel, or back) shows the
    // selected row in it (T1878).
    if (changed) if (self.selectedIndex()) |i| self.revealItem(i);
    // ...unless the all-windows list was scrolled somewhere in this layout:
    // a list that appears takes that up (T2336).
    if (changed) self.takeScroll();
    // Reaching up beside the tab strip, or no longer (T1900), moves every
    // row by the strip's height inside a column that may not have resized.
    const reach = self.window.paneSidebarReachPx();
    const reached = reach != self.reach;
    self.reach = reach;
    if (changed or reached) _ = w32.InvalidateRect(self.hwnd, null, 0);
    // A width change can cross the narrow-window line, which turns the
    // rail's toggle on or off (T2289): repaint it and re-set its tip.
    const can = self.window.paneSidebarCanExpand();
    const can_changed = can != self.can_expand;
    self.can_expand = can;
    if (can_changed and !changed and !reached) _ = w32.InvalidateRect(self.hwnd, null, 0);
    if (moved or changed or can_changed) self.syncTips();
    if (changed or can_changed) self.logOutline();
}

/// Repaint the column: what it paints over changed (the window's desk,
/// T1850) though nothing on the list did.
pub fn repaint(self: *PaneSidebar) void {
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// The window just painted desk generation `gen`. A new one (a resize - the
/// gradient spans the whole width, so even one that leaves this column the
/// same size moves its colours - or a new variant) needs this column's slice
/// repainted, or the column and the grid's margin meet at a seam.
pub fn deskPainted(self: *PaneSidebar, gen: u32) void {
    if (self.last_desk_gen == gen) return;
    self.last_desk_gen = gen;
    self.repaint();
}

/// Re-read the roster: this window's active tab, or - in the all-windows
/// scope - every tab of every window. Cheap when nothing it shows has
/// changed; repaints only when something did.
pub fn refresh(self: *PaneSidebar) void {
    if (self.all_windows) return self.refreshAll();
    const win = self.window;
    if (win.tab_count == 0) {
        if (self.entries.items.len != 0 or self.groups.items.len != 0) {
            self.clearAll();
            self.signature = 0;
            _ = w32.InvalidateRect(self.hwnd, null, 0);
        }
        return;
    }
    const tree = win.tab_trees[win.active_tab];
    const active = win.tab_active_pane[win.active_tab];
    var views: [pane_sidebar.max_items]*PaneView = undefined;
    var order_buf: [pane_sidebar_order.max_ids][]const u8 = undefined;
    const n = pane_sidebar.rosterOrdered(tree, win.paneSidebarOrder(&order_buf), &views);

    // This window's header holds the list (T2324, Mac e94a9737e): its name
    // and its fold are part of what the roster shows. The fold defaults open
    // (`shared_mod.folded`), keyed on the tab shown now.
    const key = tabKey(win, win.active_tab);
    var name_buf: [name_cap]u8 = undefined;
    const name = groupName(win, win.active_tab, &name_buf);
    const folded = self.groupFolded(key, false);

    var h = std.hash.Wyhash.init(0);
    h.update("one");
    h.update(std.mem.asBytes(&n));
    for (views[0..n]) |v| hashView(&h, v, v == active);
    h.update(name);
    h.update(std.mem.asBytes(&key));
    const fo: u8 = @intFromBool(folded);
    h.update(std.mem.asBytes(&fo));
    const sig = h.final();
    if (sig == self.signature) return;
    self.signature = sig;
    self.clearAll();
    self.appendGroup(.{
        .window = win,
        .tab = win.active_tab,
        .key = key,
        .wkey = window_order.windowKey(&win.tab_uuid[win.active_tab]),
        .label = &.{},
        .project = &.{},
        .project_key = 0,
        .project_size = 0,
        .panes = n,
        .own = true,
        .tabbed = win.tab_count > 1,
    }, ownLabel(name), null);
    self.appendEntries(views[0..n], win, win.active_tab, 0, true, active);
    self.rosterChanged();
}

/// What a row shows about `v`, into the roster's signature.
fn hashView(h: *std.hash.Wyhash, v: *PaneView, selected: bool) void {
    h.update(std.mem.asBytes(&v));
    h.update(std.mem.asBytes(&v.stash_seq));
    const sel: u8 = @intFromBool(selected);
    h.update(std.mem.asBytes(&sel));
    if (v.title()) |t| h.update(t);
    h.update("\x00");
    switch (v.kind) {
        .terminal => |s| {
            h.update(std.mem.asBytes(&s.activity_state));
            const working: u8 = @intFromBool(isWorking(v, std.time.milliTimestamp()));
            h.update(std.mem.asBytes(&working));
            h.update(std.mem.asBytes(&s.bell));
            if (s.banner_text) |b| h.update(b);
            h.update("\x00");
            if (s.pwd) |p| h.update(p);
        },
        .viewer => |vp| {
            h.update(std.mem.asBytes(&vp.mode));
            if (vp.location) |l| h.update(l);
        },
    }
    h.update("\x01");
}

/// The roster changed: repaint and re-sync the tips.
fn rosterChanged(self: *PaneSidebar) void {
    // The item being renamed went away (its pane or window closed): there
    // is nothing left to name.
    if (self.rename != null and !self.renameTargetLive()) self.endRename(false, "gone");
    self.revealSelected();
    // The rows moved under the pointer: the hovered index may name another
    // pane now.
    self.syncHoverTint();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.logOutline();
    self.logMarks();
    self.logText();
    self.syncTips();
}

/// Where the outline put everything, in the column's client coordinates -
/// once per roster or mode change, all-windows scope only. A background
/// desktop cannot be photographed row by row, so the acceptance script
/// clicks from this: heads (`W`indow / `P`roject + group), shown items
/// (group, `g`rid / `s`tashed), the hairline count and the scope toggle.
///
/// The single-window roster logs the same shape as `pane sidebar rows ...`
/// (T1845), with each item's pane id after a `#`, so the row-actions script
/// can right-click and Alt-click the row of the pane it means. Both lines
/// name the collapse/expand toggle's center and whether it can expand
/// (T2289), so a script clicks it
/// rather than re-deriving where it sits.
fn logOutline(self: *PaneSidebar) void {
    if (self.mode == .hidden) return;
    if (!self.all_windows) return self.logRows();
    const l = self.currentLayout();
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print("mode={s} heads=", .{@tagName(l.mode)}) catch {};
    for (l.heads[0..l.head_count]) |hd| {
        const k: u8 = if (hd.kind == .project) 'P' else 'W';
        w.print("{c}{d}@{d},{d};", .{ k, hd.index, hd.rect.centerX(), hd.rect.centerY() }) catch break;
    }
    w.writeAll(" items=") catch {};
    for (self.entries.items[0..@min(l.count, self.entries.items.len)], 0..) |e, i| {
        if (!l.shown(i)) continue;
        const sec: u8 = if (e.section == .stashed) 's' else 'g';
        w.print("g{d}{c}@{d},{d};", .{ e.group, sec, l.items[i].centerX(), l.items[i].centerY() }) catch break;
    }
    const rules = l.rule_count + @intFromBool(l.section_rule != null);
    w.print(" rules={d} scope={d},{d}", .{ rules, l.scope.centerX(), l.scope.centerY() }) catch {};
    self.logToggle(w, &l);
    // The search field (T1877): where to click it, and whether the "No
    // matching panes" note is up.
    if (l.search.width() > 0) {
        w.print(" search={d},{d} nomatch={d}", .{ l.search.centerX(), l.search.centerY(), @intFromBool(l.no_match != null) }) catch {};
    }
    logScroll(w, &l);
    // Each head's chevron, in heads order: a click there folds even another
    // window's group, where a click on the name raises it (T1924).
    w.writeAll(" chev=") catch {};
    for (l.heads[0..l.head_count]) |hd| {
        w.print("{d},{d};", .{ hd.chevron.centerX(), hd.chevron.centerY() }) catch break;
    }
    // Each head's hover x (T2298), in heads order.
    w.writeAll(" hx=") catch {};
    for (0..l.head_count) |k| {
        const x = l.headClose(k, self.scale);
        w.print("{d},{d};", .{ x.centerX(), x.centerY() }) catch break;
    }
    // Each head's hover + (T2323), in heads order, and the header's +.
    w.writeAll(" ha=") catch {};
    for (0..l.head_count) |k| {
        const a = l.headAdd(k, self.scale);
        w.print("{d},{d};", .{ a.centerX(), a.centerY() }) catch break;
    }
    w.print(" add={d},{d}", .{ l.add.centerX(), l.add.centerY() }) catch {};
    self.logPencils(w, &l);
    self.logHeadLook(w, &l);
    // The drag-only well (T2313): its center, or `-` at rest.
    if (l.drop_slot) |sl| {
        w.print(" tray={d},{d}", .{ sl.centerX(), sl.centerY() }) catch {};
    } else w.writeAll(" tray=-") catch {};
    log.debug("pane sidebar outline {s}", .{fbs.getWritten()});
}

/// The collapse/expand toggle on a geometry line (T2289): its center, and
/// whether a click there can expand (`can=0` is the narrow window's dimmed
/// rail button).
fn logToggle(self: *const PaneSidebar, w: anytype, l: *const pane_sidebar.Layout) void {
    w.print(" toggle={d},{d} can={d}", .{ l.toggle.centerX(), l.toggle.centerY(), @intFromBool(self.can_expand) }) catch {};
}

/// The scroll state (T1878) at the end of a geometry line: the offset of
/// its range, the viewport's top and bottom, and the pinned head (`-` for
/// none) - so the script can tell a row in view from one scrolled away.
fn logScroll(w: anytype, l: *const pane_sidebar.Layout) void {
    w.print(" scroll={d}/{d} view={d},{d} sticky=", .{ l.scroll, l.max_scroll, l.viewport.top, l.viewport.bottom }) catch return;
    if (l.sticky) |k| w.print("{d}", .{k}) catch {} else w.writeAll("-") catch {};
}

/// The rename pencils on a geometry line (T2339): each head's (`hr=`, in
/// heads order) and each shown row's (`ir=`, in the `items=` order, `-` for a
/// row that has none - a viewer's).
fn logPencils(self: *const PaneSidebar, w: anytype, l: *const pane_sidebar.Layout) void {
    w.writeAll(" hr=") catch return;
    for (0..l.head_count) |k| {
        const r = l.headRename(k, self.scale);
        w.print("{d},{d};", .{ r.centerX(), r.centerY() }) catch return;
    }
    w.writeAll(" ir=") catch return;
    for (0..@min(l.count, self.entries.items.len)) |i| {
        if (!l.shown(i)) continue;
        const r = l.rowRename(i, self.scale);
        if (r.width() > 0) {
            w.print("{d},{d};", .{ r.centerX(), r.centerY() }) catch return;
        } else w.writeAll("-;") catch return;
    }
}

/// Each head's look on a geometry line (T2340), in heads order: its window
/// icon's center (`hicon=`, `-` on a project head) and whether it is drawn
/// selected (`hsel=`, this window's folded header).
fn logHeadLook(self: *const PaneSidebar, w: anytype, l: *const pane_sidebar.Layout) void {
    w.writeAll(" hicon=") catch return;
    for (l.heads[0..l.head_count]) |hd| {
        if (hd.icon.width() > 0) {
            w.print("{d},{d};", .{ hd.icon.centerX(), hd.icon.centerY() }) catch return;
        } else w.writeAll("-;") catch return;
    }
    w.writeAll(" hsel=") catch return;
    for (l.heads[0..l.head_count]) |hd| {
        const sel = hd.index < self.groups.items.len and self.headDrawnSelected(hd, self.groups.items[hd.index]);
        w.print("{d}", .{@intFromBool(sel)}) catch return;
    }
}

/// Whether `paintHead` draws header `hd` selected (`pane_sidebar.headSelected`).
fn headDrawnSelected(self: *const PaneSidebar, hd: pane_sidebar.Head, g: Group) bool {
    const folded = if (hd.kind == .project) self.folded_projects.contains(g.project_key) else self.groupFolded(g.key, self.filterActive());
    return pane_sidebar.headSelected(hd.kind, g.own, folded);
}

fn logRows(self: *PaneSidebar) void {
    const l = self.currentLayout();
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    // This window's header (T2324): the outline line's `W` shape.
    w.print("mode={s} heads=", .{@tagName(l.mode)}) catch {};
    for (l.heads[0..l.head_count]) |hd| {
        w.print("W{d}@{d},{d};", .{ hd.index, hd.rect.centerX(), hd.rect.centerY() }) catch break;
    }
    w.writeAll(" items=") catch {};
    for (self.entries.items[0..@min(l.count, self.entries.items.len)], 0..) |e, i| {
        if (!l.shown(i)) continue;
        const sec: u8 = if (e.section == .stashed) 's' else 'g';
        w.print("g0{c}@{d},{d}#{s};", .{ sec, l.items[i].centerX(), l.items[i].centerY(), e.pane.paneId() }) catch break;
    }
    const rules = l.rule_count + @intFromBool(l.section_rule != null);
    w.print(" rules={d} scope={d},{d} add={d},{d}", .{ rules, l.scope.centerX(), l.scope.centerY(), l.add.centerX(), l.add.centerY() }) catch {};
    // The header's chevron, hover x and hover + (panel), and the rail's +
    // in its slot (`-` where there is none).
    if (l.head_count > 0) {
        const hd = l.heads[0];
        const x = l.headClose(0, self.scale);
        const a = l.headAdd(0, self.scale);
        w.print(" chev={d},{d}; hx={d},{d}; ha={d},{d};", .{ hd.chevron.centerX(), hd.chevron.centerY(), x.centerX(), x.centerY(), a.centerX(), a.centerY() }) catch {};
    }
    self.logPencils(w, &l);
    self.logHeadLook(w, &l);
    if (l.rail_add.width() > 0) {
        w.print(" radd={d},{d}", .{ l.rail_add.centerX(), l.rail_add.centerY() }) catch {};
    } else w.writeAll(" radd=-") catch {};
    self.logToggle(w, &l);
    logScroll(w, &l);
    // The empty tray (T2276): its well's center, or `-` while something is
    // stashed, and whether a STASHED caption is laid out over it (never,
    // since T2313 - the script asserts the 0).
    if (l.drop_slot) |sl| {
        w.print(" tray={d},{d} cap={d}", .{ sl.centerX(), sl.centerY(), @intFromBool(l.stashed_caption != null) }) catch {};
    } else w.writeAll(" tray=-") catch {};
    log.debug("pane sidebar rows {s}", .{fbs.getWritten()});
}

/// The roster's activity marks, logged when the tally moves: how many rows
/// are busy and carry a bell dot (a stashed pane whose bell rang). The
/// acceptance script scores the bell from this line, since a dot is a few
/// pixels on a background desktop. A question has no mark in the sidebar
/// (T2280, Mac 2924ea5cc), so it is not counted.
fn logMarks(self: *PaneSidebar) void {
    var tally: [2]usize = .{ 0, 0 };
    for (self.entries.items) |e| {
        if (e.busy) tally[0] += 1;
        if (e.bell and e.section == .stashed) tally[1] += 1;
    }
    if (std.mem.eql(usize, &tally, &self.logged_marks)) return;
    self.logged_marks = tally;
    log.info("pane sidebar marks busy={d} bell={d}", .{ tally[0], tally[1] });
}

/// What each row says - pane id, title and subtitle - logged when it changes,
/// for the acceptance script: text drawn on a background desktop cannot be
/// read back, and the title rule (a banner's title names its pane, T2085) is
/// exactly what it scores.
fn logText(self: *PaneSidebar) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    for (self.entries.items) |e| {
        var t8: [name_cap]u8 = undefined;
        var s8: [name_cap]u8 = undefined;
        const tn = std.unicode.utf16LeToUtf8(&t8, e.title[0..@min(e.title.len, name_cap / 3)]) catch 0;
        const sn = std.unicode.utf16LeToUtf8(&s8, e.subtitle[0..@min(e.subtitle.len, name_cap / 3)]) catch 0;
        w.print(" #{s} title={s} sub={s};", .{ e.pane.paneId(), t8[0..tn], s8[0..sn] }) catch break;
    }
    const line = fbs.getWritten();
    const h = std.hash.Wyhash.hash(0x74657874, line);
    if (h == self.logged_text) return;
    self.logged_text = h;
    log.debug("pane sidebar text{s}", .{line});
}

const TabRef = struct { window: *Window, tab: usize };
const name_cap = 768; // a 256-unit tab title as UTF-8

/// The all-windows roster (T1829): every tab of every window as a group, in
/// outline order (`pane_sidebar_outline.outlineOrder`), each listing its
/// panes the way this window's own roster does.
fn refreshAll(self: *PaneSidebar) void {
    const max_heads = pane_sidebar.max_heads;
    var refs: [max_heads]TabRef = undefined;
    var names_buf: [max_heads][name_cap]u8 = undefined;
    var names: [max_heads][]const u8 = undefined;
    var nref: usize = 0;
    gather: for (self.window.app.windows.items) |w| {
        if (w.closing or w.is_quick_terminal) continue;
        for (0..w.tab_count) |t| {
            if (nref == max_heads) break :gather;
            refs[nref] = .{ .window = w, .tab = t };
            names[nref] = groupName(w, t, &names_buf[nref]);
            nref += 1;
        }
    }
    // Name order, then the user's (T2337): the order every window shares.
    var wkey_bufs: [max_heads]window_order.Key = undefined;
    var wkeys: [max_heads][]const u8 = undefined;
    for (refs[0..nref], 0..) |r, i| {
        wkey_bufs[i] = window_order.windowKey(&r.window.tab_uuid[r.tab]);
        wkeys[i] = wkey_bufs[i].slice();
    }
    var by_name: [max_heads]outline.Placed = undefined;
    const n_name = outline.outlineOrder(names[0..nref], &by_name);
    var worder_buf: [window_order.max_keys][]const u8 = undefined;
    var all_placed: [max_heads]outline.Placed = undefined;
    const n_all = window_order.arrange(by_name[0..n_name], wkeys[0..nref], shared.windowOrder(&worder_buf), &all_placed);

    // Searching (T1877): only the panes the query matches, only the windows
    // holding one, and nothing folded - a hit inside a folded group would
    // read as no hit (Mac `allWindows`).
    var q_buf: [search_field.cap * 3]u8 = undefined;
    const query: ?[]const u8 = if (self.filterActive()) self.search.utf8(&q_buf) else null;
    const home = if (query != null) std.process.getEnvVarOwned(self.alloc, "USERPROFILE") catch null else null;
    defer if (home) |hm| self.alloc.free(hm);

    const Span = struct { start: usize, grid: usize, stashed: usize };
    var views: [pane_sidebar.max_items]*PaneView = undefined;
    var spans: [max_heads]Span = undefined;
    var placed: [max_heads]outline.Placed = undefined;
    var np: usize = 0;
    var nv: usize = 0;
    var h = std.hash.Wyhash.init(0);
    h.update("all");
    h.update(std.mem.asBytes(&n_all));
    if (query) |q| {
        h.update("search\x00");
        h.update(q);
    }
    for (all_placed[0..n_all]) |p| {
        const r = refs[p.index];
        const own = self.isOwn(r);
        const active = r.window.tab_active_pane[r.tab];
        var order_buf: [pane_sidebar_order.max_ids][]const u8 = undefined;
        const order = r.window.paneSidebarOrder(&order_buf);
        const listed = pane_sidebar.rosterOrdered(r.window.tab_trees[r.tab], order, views[nv..]);
        // Keep the hits, in roster order (the grid, then the stash).
        var got: usize = 0;
        var grid: usize = 0;
        for (views[nv .. nv + listed]) |v| {
            if (query) |q| {
                if (!paneMatches(q, names[p.index], v, home)) continue;
            }
            views[nv + got] = v;
            got += 1;
            if (v.stash_seq == 0) grid += 1;
        }
        if (query != null and got == 0) continue;
        const gi = np;
        placed[gi] = p;
        np += 1;
        spans[gi] = .{ .start = nv, .grid = grid, .stashed = got - grid };
        h.update(std.mem.asBytes(&r.window));
        h.update(std.mem.asBytes(&r.tab));
        h.update(names[p.index]);
        h.update("\x00");
        const o: u8 = @intFromBool(own);
        h.update(std.mem.asBytes(&o));
        const q: u8 = @intFromBool(r.window.tab_count > 1);
        h.update(std.mem.asBytes(&q));
        h.update(std.mem.asBytes(&got));
        for (views[nv .. nv + got]) |v| hashView(&h, v, self.rowSelected(own, v, active));
        nv += got;
    }
    inline for (.{ &self.unfolded, &self.folded_projects }) |set| {
        var fold_acc: u64 = 0;
        var fit = set.keyIterator();
        while (fit.next()) |k| fold_acc ^= k.*;
        h.update(std.mem.asBytes(&fold_acc));
        h.update(std.mem.asBytes(&set.count()));
    }
    self.window_count = n_all;
    const sig = h.final();
    if (sig == self.signature) return;
    self.signature = sig;

    self.clearAll();
    var specs: [max_heads]outline.GroupSpec = undefined;
    for (placed[0..np], 0..) |p, gi| {
        const r = refs[p.index];
        const own = self.isOwn(r);
        const sp = spans[gi];
        const key = tabKey(r.window, r.tab);
        const project_key: u64 = if (p.project) |pr| projectKey(pr) else 0;
        self.appendGroup(.{
            .window = r.window,
            .tab = r.tab,
            .key = key,
            .wkey = wkey_bufs[p.index],
            .pkey = if (p.project) |pr| window_order.projectKey(pr) else .{},
            .label = &.{},
            .project = &.{},
            .project_key = project_key,
            .project_size = if (outline.opensProject(placed[0..np], gi)) outline.projectSize(placed[0..np], gi) else 0,
            .panes = sp.grid + sp.stashed,
            .own = own,
            .tabbed = r.window.tab_count > 1,
        }, p.label, p.project);
        self.appendEntries(views[sp.start .. sp.start + sp.grid + sp.stashed], r.window, r.tab, @intCast(gi), own, r.window.tab_active_pane[r.tab]);
        specs[gi] = .{
            .project = p.project,
            .grid = sp.grid,
            .stashed = sp.stashed,
            .folded = self.groupFolded(key, query != null),
            .project_folded = query == null and p.project != null and self.folded_projects.contains(project_key),
        };
    }
    var lines: [pane_sidebar.max_heads * 5 + pane_sidebar.max_items]pane_sidebar.Line = undefined;
    const nl = outline.buildLines(specs[0..np], &lines);
    self.lines.appendSlice(self.alloc, lines[0..nl]) catch {};
    // The order, for the acceptance script: `project/worktree` or the name.
    var ob: [1024]u8 = undefined;
    var ofs = std.io.fixedBufferStream(&ob);
    for (placed[0..np], 0..) |p, gi| {
        const sep: []const u8 = if (gi == 0) "" else "|";
        if (p.project) |pr| {
            ofs.writer().print("{s}{s}/{s}", .{ sep, pr, p.label }) catch break;
        } else ofs.writer().print("{s}{s}", .{ sep, p.label }) catch break;
    }
    const terms = if (query) |q| countTerms(q) else 0;
    var folds: usize = 0;
    for (specs[0..np]) |s| folds += @intFromBool(s.folded);
    log.debug("pane sidebar all-windows groups={d} panes={d} lines={d} search={d} windows={d} folded={d} order={s}", .{ np, nv, nl, terms, n_all, folds, ofs.getWritten() });
    self.rosterChanged();
}

/// Whether window group `key` is folded now (`shared_mod.folded`).
fn groupFolded(self: *const PaneSidebar, key: u64, searching: bool) bool {
    return shared_mod.folded(self.all_windows, &self.unfolded, &self.folded_this, key, searching);
}

/// Whether `v`'s row is drawn selected: this window's focused pane - or, in
/// the all-windows list, another window's row just clicked here (T2336).
fn rowSelected(self: *const PaneSidebar, own: bool, v: *const PaneView, active: *const PaneView) bool {
    if (self.all_windows) if (self.clicked) |c| return v == c;
    return own and v == active;
}

fn countTerms(q: []const u8) usize {
    var n: usize = 0;
    var it = outline.terms(q);
    while (it.next()) |_| n += 1;
    return n;
}

/// Whether the search filters the roster now (`pane_sidebar_search.filters`).
fn filterActive(self: *const PaneSidebar) bool {
    return search_field.filters(!self.search.isEmpty(), self.all_windows, self.mode == .expanded);
}

/// Whether `query` matches pane `v` of the window called `window_name`: every
/// term in the window's name or in what the pane's row says about it - its
/// title, its banner line, and its directory or location both as shown and
/// in full (Mac `PaneSidebarText.searchFields`), so `~\git` and
/// `C:\Users\me\git` each find it.
fn paneMatches(query: []const u8, window_name: []const u8, v: *PaneView, home: ?[]const u8) bool {
    const kind_name: []const u8 = if (v.isViewer()) "Viewer" else "Terminal";
    const pwd: ?[]const u8 = if (v.surface()) |s| (if (s.pwd) |p| p else null) else null;
    var title_buf: [512]u8 = undefined;
    const label8 = pane_sidebar.paneLabel(if (v.title()) |t| t else null, pwd, kind_name, bannerOf(v), v.userTitled(), &title_buf);
    // The pane's own title still finds it when a banner title hides it (T2085).
    const own8: ?[]const u8 = if (v.title()) |t| t else null;
    var line_buf: [512]u8 = undefined;
    const banner = pane_sidebar.bannerLine(bannerOf(v), &line_buf);
    const location: ?[]const u8 = if (v.viewer()) |vp| (if (vp.location) |l| l else null) else null;
    var pwd_buf: [512]u8 = undefined;
    var loc_buf: [512]u8 = undefined;
    const pwd_short: ?[]const u8 = if (pwd) |p| pane_sidebar.abbreviatePath(p, home, &pwd_buf) else null;
    const loc_short: ?[]const u8 = if (location) |l| pane_sidebar.abbreviatePath(l, home, &loc_buf) else null;
    return outline.matches(query, &.{ window_name, label8, own8, banner, pwd, pwd_short, location, loc_short });
}

/// A terminal pane's banner text; a viewer has none.
fn bannerOf(v: *PaneView) ?[]const u8 {
    return switch (v.kind) {
        .terminal => |s| if (s.banner_text) |b| b else null,
        .viewer => null,
    };
}

fn isOwn(self: *const PaneSidebar, r: TabRef) bool {
    return r.window == self.window and r.tab == self.window.active_tab;
}

/// A window's name as a person would say it (Mac `windowTitle(of:)`): a title
/// the user set - the window's, else the tab's - and otherwise what its
/// focused pane is called. Never the raw title with its activity suffix.
fn groupName(w: *Window, t: usize, buf: *[name_cap]u8) []const u8 {
    if (w.title_override) |o| {
        if (o.len > 0) return o;
    }
    if (w.tab_title_pinned[t]) {
        const n = std.unicode.utf16LeToUtf8(buf, w.tab_titles[t][0..w.tab_title_lens[t]]) catch 0;
        if (n > 0) return buf[0..n];
    }
    const pane = w.tab_active_pane[t];
    const pwd: ?[]const u8 = if (pane.surface()) |s| (if (s.pwd) |p| p else null) else null;
    return pane_sidebar.displayTitle(if (pane.title()) |x| x else null, pwd, "Window");
}

/// This window's own list names it as the all-windows list does (T2339, Mac
/// a13bf6f43): `<name>` for a `<project>: <name>` window.
fn ownLabel(name: []const u8) []const u8 {
    return if (outline.splitWindowTitle(name)) |sp| sp.worktree else name;
}

fn tabKey(w: *const Window, t: usize) u64 {
    return std.hash.Wyhash.hash(0x746162, &w.tab_uuid[t]);
}

fn projectKey(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x70726f6a, name);
}

fn appendGroup(self: *PaneSidebar, g_in: Group, label8: []const u8, project8: ?[]const u8) void {
    var g = g_in;
    g.label = std.unicode.utf8ToUtf16LeAlloc(self.alloc, label8) catch return;
    var up: [name_cap]u8 = undefined;
    const p8 = project8 orelse "";
    const pn = @min(p8.len, up.len);
    for (p8[0..pn], 0..) |c, i| up[i] = std.ascii.toUpper(c);
    g.project = std.unicode.utf8ToUtf16LeAlloc(self.alloc, up[0..pn]) catch {
        self.alloc.free(g.label);
        return;
    };
    self.groups.append(self.alloc, g) catch {
        self.alloc.free(g.label);
        self.alloc.free(g.project);
    };
}

fn clearEntries(self: *PaneSidebar) void {
    for (self.entries.items) |e| {
        self.alloc.free(e.title);
        self.alloc.free(e.subtitle);
    }
    self.entries.clearRetainingCapacity();
}

fn clearGroups(self: *PaneSidebar) void {
    for (self.groups.items) |g| {
        self.alloc.free(g.label);
        self.alloc.free(g.project);
    }
    self.groups.clearRetainingCapacity();
}

fn clearAll(self: *PaneSidebar) void {
    self.clearEntries();
    self.clearGroups();
    self.lines.clearRetainingCapacity();
}

fn appendEntries(self: *PaneSidebar, views: []const *PaneView, window: *Window, tab: usize, group: u16, own: bool, active: *PaneView) void {
    var home_buf: [512]u8 = undefined;
    const home = std.process.getEnvVarOwned(self.alloc, "USERPROFILE") catch null;
    defer if (home) |hm| self.alloc.free(hm);
    const now_ms = std.time.milliTimestamp();
    for (views) |v| {
        const kind_name: []const u8 = if (v.isViewer()) "Viewer" else "Terminal";
        const pwd: ?[]const u8 = if (v.surface()) |s| (if (s.pwd) |p| p else null) else null;
        // The banner's title names the row (and so the tile's tip) when it
        // has one (T2085).
        var title_buf: [512]u8 = undefined;
        const title8 = pane_sidebar.paneLabel(if (v.title()) |t| t else null, pwd, kind_name, bannerOf(v), v.userTitled(), &title_buf);

        var line_buf: [512]u8 = undefined;
        const subtitle8: ?[]const u8 = blk: {
            switch (v.kind) {
                .terminal => |s| {
                    if (pane_sidebar.bannerSubtitle(if (s.banner_text) |b| b else null, &line_buf)) |l| break :blk l;
                    if (pwd) |p| {
                        // A shell titled by its own directory (cmd and pwsh
                        // do that) would show the same place twice.
                        if (pane_sidebar.samePath(p, title8)) break :blk null;
                        break :blk pane_sidebar.abbreviatePath(p, home, &home_buf);
                    }
                    break :blk null;
                },
                .viewer => |vp| break :blk if (vp.location) |l| l else null,
            }
        };
        const sub8 = pane_sidebar.distinct(subtitle8, title8) orelse "";

        const title = std.unicode.utf8ToUtf16LeAlloc(self.alloc, title8) catch continue;
        const subtitle = std.unicode.utf8ToUtf16LeAlloc(self.alloc, sub8) catch {
            self.alloc.free(title);
            continue;
        };
        self.entries.append(self.alloc, .{
            .pane = v,
            .window = window,
            .tab = tab,
            .group = group,
            .own = own,
            .section = if (v.stash_seq != 0) .stashed else .grid,
            .title = title,
            .subtitle = subtitle,
            .icon = iconFor(v),
            .hue = @intCast(@min(pane_hue.treeIndex(window.tab_trees[tab], v), std.math.maxInt(u16))),
            .busy = isWorking(v, now_ms),
            .bell = if (v.surface()) |s| s.bell else false,
            // Only THIS window has a selection (Mac 55352e377): another
            // window's focus is not focus here - unless its row was just
            // clicked here (T2336).
            .selected = self.rowSelected(own, v, active),
        }) catch {
            self.alloc.free(title);
            self.alloc.free(subtitle);
        };
    }
}

/// Every OTHER sidebar showing all windows re-reads its roster: something in
/// `except` (or a window that just closed, with `except` null) changed what
/// they list. Cheap - each hashes and returns when nothing it shows moved.
pub fn refreshScopes(windows: []const *Window, except: ?*Window) void {
    for (windows) |w| {
        if (w == except or w.closing) continue;
        const sb = w.sidebar orelse continue;
        if (sb.all_windows) sb.refresh();
    }
}

fn iconFor(v: *const PaneView) u16 {
    const vp = v.viewer() orelse return glyph_terminal;
    return switch (vp.mode) {
        .markdown => glyph_document,
        .web => glyph_globe,
        .image => glyph_photo,
        else => glyph_code,
    };
}

// -------------------------------------------------------------------------
// Layout
// -------------------------------------------------------------------------

/// The layout as it is on screen: laid out, then scrolled to the offset
/// (T1878) - which is clamped here, so a list that shrank never leaves the
/// offset pointing past its end. Everything that paints, hits, drops or tips
/// goes through this one funnel, so they cannot disagree about where a
/// scrolled row is.
fn currentLayout(self: *PaneSidebar) pane_sidebar.Layout {
    var l = self.rawLayout();
    scroll_mod.apply(&l, self.scroll, self.scale);
    self.scroll = l.scroll;
    return l;
}

/// The layout before the scroll pass: every row where it would sit in a
/// column as tall as its content.
fn rawLayout(self: *PaneSidebar) pane_sidebar.Layout {
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &r) == 0) return .{};
    // Mid-glide the column is drawn narrower or wider than its mode lays out
    // (T2291): the layout - what is painted, hit and scrolled - is the one it
    // is going to.
    if (self.column) |c| r.right = r.left + c.to_w;
    var items: [pane_sidebar.max_items]pane_sidebar.Item = undefined;
    const n = @min(self.entries.items.len, items.len);
    for (self.entries.items[0..n], 0..) |e, i| {
        items[i] = .{ .section = e.section, .two_line = e.subtitle.len > 0, .group = e.group, .own = e.own, .renamable = rename_rules.offersPencil(.pane, e.pane.isViewer()) };
    }
    self.ensureFonts();
    const lines: ?[]const pane_sidebar.Line = if (self.all_windows) self.lines.items else null;
    const insets = self.window.paneSidebarInsets();
    var l = pane_sidebar.layoutIn(self.mode, r.right - r.left, r.bottom - r.top, items[0..n], lines, self.metrics, self.scale, insets);
    // This window's header over its panes, or the rail's + in its slot
    // (T2324) - before the tray, which follows the rows it moves.
    if (lines == null and self.groups.items.len > 0) {
        pane_sidebar.addThisWindowHead(&l, self.groupFolded(self.groups.items[0].key, false), self.metrics, self.scale);
    }
    // The empty tray is always there (T2276, Mac 543489bca): a drop target
    // says so before a drag starts, not only once one is under way.
    pane_sidebar.addEmptyTray(&l, self.metrics, self.scale);
    // All windows: the well only while a pane is dragged (T2313, Mac
    // b7de64ce8) - at rest the list is every window's panes and nothing else.
    if (self.drag_active) pane_sidebar.addDragWell(&l, self.metrics, self.scale);
    l.search_text = !self.search.isEmpty();
    return l;
}

// -------------------------------------------------------------------------
// Scrolling (T1878)
// -------------------------------------------------------------------------

/// The selected pane's entry: this window's focused pane.
fn selectedIndex(self: *const PaneSidebar) ?usize {
    for (self.entries.items, 0..) |e, i| {
        if (e.selected) return i;
    }
    return null;
}

/// Bring the selected row into view, once per NEW selection: focus moving
/// to a pane whose row is past the fold scrolls to it (Mac's list follows
/// the selection), while a roster refresh for anything else leaves the
/// user's own scrolling alone.
fn revealSelected(self: *PaneSidebar) void {
    const i = self.selectedIndex() orelse return;
    const pane = self.entries.items[i].pane;
    if (self.revealed == pane) return;
    self.revealed = pane;
    self.revealItem(i);
}

/// Scroll the least that shows item `i` (a no-op when it shows). The log
/// keeps its `surface=rail` field: the hover-open card was the other
/// surface until T2289, and the scripts read the line as it was.
fn revealItem(self: *PaneSidebar, i: usize) void {
    const raw = self.rawLayout();
    if (i >= raw.count or !raw.shown(i)) return;
    const before = self.scroll;
    self.scroll = scroll_mod.revealOffset(&raw, raw.items[i], before, self.scale);
    if (self.scroll != before) log.info("pane sidebar reveal surface=rail item={d} scroll={d}", .{ i, self.scroll });
}

/// Scroll to `want` (clamped), and follow everything that hangs off a row's
/// position: the paint, the tips, the hover under a pointer that did not
/// move, and the geometry line the acceptance script reads.
fn scrollTo(self: *PaneSidebar, want: i32) void {
    const before = self.scroll;
    self.scroll = want;
    const l = self.currentLayout();
    if (l.scroll == before) return;
    // The all-windows list scrolls as one (T2336): the last list scrolled
    // is where every other takes up when it is next activated.
    if (self.all_windows) shared.recordScroll(shared_mod.Surface.of(self.mode == .expanded), l.scroll);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.syncTips();
    log.info("pane sidebar scroll surface=rail offset={d}/{d}", .{ l.scroll, l.max_scroll });
    self.logOutline();
    var pt: w32.POINT = undefined;
    if (self.thumb_drag == null and w32.GetCursorPos_(&pt) != 0 and w32.ScreenToClient(self.hwnd, &pt) != 0) {
        var cr: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &cr) != 0 and pt.x >= 0 and pt.y >= 0 and pt.x < cr.right and pt.y < cr.bottom) {
            self.setHover(self.hitAt(pt.x, pt.y));
        }
    }
}

const SPI_GETWHEELSCROLLLINES: u32 = 0x0068;
const WHEEL_PAGESCROLL: u32 = 0xFFFF_FFFF;

/// A wheel notch: the system's lines per notch, a line being one pane row
/// and its gap, on the rail or the panel; "one screen" scrolls by the
/// viewport.
fn onWheel(self: *PaneSidebar, delta: i32) void {
    const l = self.currentLayout();
    if (l.max_scroll <= 0) return;
    var lines: u32 = 3;
    _ = w32.SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, @ptrCast(&lines), 0);
    // A line is one pane row - a full row and a tile are one height (T2279).
    var line_h = pane_sidebar.pillHeight(self.metrics, self.scale) + pane_sidebar.rowGap(self.scale);
    if (lines == WHEEL_PAGESCROLL) {
        lines = 1;
        line_h = l.viewport.height();
    }
    self.scrollTo(self.scroll + self.wheel.step(delta, lines, line_h));
}

/// Where in the thumb a press at (`x`, `y`) took it, or null off it. The
/// target is wider than the thin thumb - out to the viewport's edge - and
/// wins over the resize band on its own height only.
fn thumbAt(self: *PaneSidebar, x: i32, y: i32) ?i32 {
    const l = self.currentLayout();
    const t = scroll_mod.thumb(&l, self.scale) orelse return null;
    const slop = pane_sidebar.px(4, self.scale);
    if (x < t.left - slop or x >= l.viewport.right or y < t.top or y >= t.bottom) return null;
    return y - t.top;
}

// -------------------------------------------------------------------------
// Drag and drop (T1844)
// -------------------------------------------------------------------------

/// The sidebar as a pane-drop target, in screen coordinates.
pub const DropGeometry = struct {
    /// Anywhere on it means stash: the column.
    sidebar: pane_drop.Rect,
    /// The stashed rows (rail tiles), top to bottom.
    rows: []const pane_drop.Rect,
    /// The empty "Drop to stash" slot, while a drag shows one.
    slot: ?pane_drop.Rect,
    /// This window's LIST rows - its panes on the grid, in the list's order
    /// (T2303) - and where the tray begins below them (`pane_drop.sidebarHit`).
    list: []const pane_drop.PaneRect = &.{},
    tray_top: ?i32 = null,
};

/// The drop target this sidebar presents right now, or null while it is
/// hidden (Mac: a sidebar hidden outright is not a target; the rail always
/// is). Rows are written into `rows_out` (and the list's into `list_out`) and
/// borrowed by the answer.
pub fn dropGeometry(self: *PaneSidebar, rows_out: []pane_drop.Rect, list_out: []pane_drop.PaneRect) ?DropGeometry {
    if (self.mode == .hidden) return null;
    if (w32.IsWindowVisible(self.hwnd) == 0) return null;
    var col: w32.RECT = undefined;
    if (w32.GetWindowRect(self.hwnd, &col) == 0) return null;
    var origin = w32.POINT{ .x = 0, .y = 0 };
    _ = w32.ClientToScreen(self.hwnd, &origin);
    const l = self.currentLayout();
    const area: pane_drop.Rect = .{ .left = col.left, .top = col.top, .right = col.right, .bottom = col.bottom };
    var n: usize = 0;
    var i = l.first_stashed;
    const end = if (l.outline) l.stash_end else l.count;
    while (i < end and n < rows_out.len) : (i += 1) {
        // A stashed row folded out of sight - or scrolled out of it (T1878)
        // - is no place to drop between; one half in view offers that half.
        if (!l.shown(i)) continue;
        const v = scroll_mod.visible(&l, l.items[i]);
        if (v.height() <= 0) continue;
        rows_out[n] = toScreen(v, origin);
        n += 1;
    }
    const slot: ?pane_drop.Rect = if (l.drop_slot) |sl| blk: {
        const v = scroll_mod.visible(&l, sl);
        break :blk if (v.height() > 0) toScreen(v, origin) else null;
    } else null;
    // The list: this window's grid rows (T2303). A row scrolled out of sight
    // keeps its laid-out place - the index counts it either way - so it is
    // listed unclipped, as the order is.
    var nl: usize = 0;
    var last_list: ?pane_sidebar.Rect = null;
    for (0..@min(l.count, self.entries.items.len)) |li| {
        const e = self.entries.items[li];
        if (!e.own or e.section != .grid or !l.shown(li)) continue;
        last_list = l.items[li];
        if (nl == list_out.len) continue;
        list_out[nl] = .{ .id = e.pane.paneId(), .rect = toScreen(l.items[li], origin) };
        nl += 1;
    }
    return .{
        .sidebar = area,
        .rows = rows_out[0..n],
        .slot = slot,
        .list = list_out[0..nl],
        .tray_top = if (trayTop(&l, last_list)) |y| y + origin.y else null,
    };
}

/// Where the tray begins, in client coordinates (T2303, Mac `trayTop`). The
/// single roster draws it: the hairline over the STASHED caption, or over the
/// empty tray's well. The all-windows outline has no hairline of this window's
/// own, so the tray begins between this window's last list row and its first
/// stashed one - or right under the last list row when nothing is stashed.
fn trayTop(l: *const pane_sidebar.Layout, last_list: ?pane_sidebar.Rect) ?i32 {
    if (!l.outline) {
        const rule = l.section_rule orelse return null;
        return rule.top;
    }
    const has_stash = l.first_stashed < l.stash_end and l.shown(l.first_stashed);
    if (has_stash) {
        const first = l.items[l.first_stashed];
        const above = last_list orelse return first.top;
        return @divFloor(above.bottom + first.top, 2);
    }
    const above = last_list orelse return null;
    return above.bottom;
}

fn toScreen(r: pane_sidebar.Rect, origin: w32.POINT) pane_drop.Rect {
    return .{ .left = r.left + origin.x, .top = r.top + origin.y, .right = r.right + origin.x, .bottom = r.bottom + origin.y };
}

/// A pane drag started or ended (in any window: every sidebar is a target).
pub fn setDragActive(self: *PaneSidebar, on: bool) void {
    if (self.drag_active == on) return;
    self.drag_active = on;
    if (!on) self.endDragMotion();
    // The empty "Drop to stash" slot sits under the last row: a long list
    // scrolls it into view, so the target is there to aim at (T1878).
    if (on) {
        const raw = self.rawLayout();
        if (raw.drop_slot) |sl| self.scroll = scroll_mod.revealOffset(&raw, sl, self.scroll, self.scale);
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    // All windows opens and closes its well with the drag (T2313): the
    // rows below it move, so their tips follow, and the geometry line says
    // where it is, or that it went.
    if (self.all_windows) {
        self.syncTips();
        self.logOutline();
    }
}

/// A press on a row that has travelled far enough is a DRAG of that pane:
/// hand it to the window's pane drag (the one resolver, the one preview).
/// True when it did, and the press is no longer this sidebar's.
fn maybeStartRowDrag(self: *PaneSidebar, hwnd: w32.HWND, x: i32, y: i32) bool {
    if (w32.GetCapture() != hwnd) return false;
    const i = switch (self.pressed) {
        .item => |i| i,
        else => return false,
    };
    if (!drop_highlight.exceedsThreshold(x - self.press_x, y - self.press_y, drop_highlight.thresholdPx(self.scale))) return false;
    if (i >= self.entries.items.len) return false;
    // Another window's pane is not dragged from here yet: dropping it into
    // this grid or onto another window's group is the cross-window move,
    // which is its own follow-up (T1829 split).
    if (!self.entries.items[i].own) return false;
    const pane = self.entries.items[i].pane;
    self.pressed = .none;
    _ = w32.InvalidateRect(hwnd, null, 0);
    var press = w32.POINT{ .x = self.press_x, .y = self.press_y };
    _ = w32.ClientToScreen(hwnd, &press);
    var cur = w32.POINT{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &cur);
    log.info("pane sidebar row drag start item={d} section={s}", .{ i, @tagName(self.entries.items[i].section) });
    // The row itself follows the pointer from here (T2304).
    self.stopReorderClock();
    self.drag = .{ .pane = pane, .held = .{ .press_y = self.press_y } };
    self.window.beginSidebarDrag(pane, press, cur);
    return true;
}

fn makeFont(height: i32, weight: i32) ?*anyopaque {
    return w32.CreateFontW(
        -height,
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
    );
}

fn ensureFonts(self: *PaneSidebar) void {
    if (self.title_font != null and self.font_scale == self.scale) return;
    self.releaseFonts();
    const body = type_ramp.body(self.scale);
    const cap = type_ramp.caption(self.scale);
    self.title_font = makeFont(body.height, body.weight);
    self.title_bold_font = makeFont(body.height, type_ramp.weight_semibold);
    self.caption_font = makeFont(cap.height, cap.weight);
    self.caption_bold_font = makeFont(cap.height, type_ramp.weight_semibold);
    self.font_scale = self.scale;
    // One line of each, measured rather than assumed from the em size.
    const hdc = w32.GetDC(self.hwnd) orelse return;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    self.metrics = .{
        .title_h = lineHeight(hdc, self.title_font),
        .caption_h = lineHeight(hdc, self.caption_font),
    };
}

fn lineHeight(hdc: w32.HDC, font: ?*anyopaque) i32 {
    const f = font orelse return 16;
    const prev = w32.SelectObject(hdc, @ptrCast(f));
    defer if (prev) |p| {
        _ = w32.SelectObject(hdc, p);
    };
    var probe = [_]u16{ 'A', 'g' };
    var r = w32.RECT{ .left = 0, .top = 0, .right = 1000, .bottom = 0 };
    _ = w32.DrawTextW(hdc, &probe, 2, &r, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
    return @max(r.bottom - r.top, 1);
}

fn releaseFonts(self: *PaneSidebar) void {
    inline for (.{ "title_font", "title_bold_font", "caption_font", "caption_bold_font" }) |name| {
        if (@field(self, name)) |f| _ = w32.DeleteObject(@ptrCast(f));
        @field(self, name) = null;
    }
    self.font_scale = 0;
}

// -------------------------------------------------------------------------
// Paint
// -------------------------------------------------------------------------

const Theme = struct {
    bg: color_math.Rgb,
    surface: color_math.Rgb,
    text: u32,
    secondary: u32,
    accent: color_math.Rgb,
    dark: bool,
    /// The primary text as a color, for blends against the surface.
    ink: color_math.Rgb,
};

/// The sidebar's hairlines - above all the tray's, the line a pane is dragged
/// below to stash it: the primary at 22% over the surface, so it reads on
/// glass (Mac 0a547522d `PaneSidebarDivider`; a 24-step shade, ~9%, all but
/// vanished there).
fn ruleColor(t: Theme) u32 {
    return rgb(color_math.mix(t.surface, t.ink, 0.22));
}

fn theme(self: *const PaneSidebar) Theme {
    const c = self.window.app.config.background;
    const bg: color_math.Rgb = .{ .r = c.r, .g = c.g, .b = c.b };
    // Pinned: the terminal background lifted by the card wash. Rail: the
    // card's own fill is the surface its tiles sit on.
    const surface = banner_card.fillColor(bg);
    const text = chrome_theme.textOn(surface);
    const secondary = chrome_theme.textSecondaryOn(surface);
    return .{
        .bg = bg,
        .surface = surface,
        .text = w32.RGB(text.r, text.g, text.b),
        .secondary = w32.RGB(secondary.r, secondary.g, secondary.b),
        .accent = chrome_theme.accentOn(surface, system_colors.accentCached()),
        .dark = !color_math.isLight(bg),
        .ink = text,
    };
}

fn fillRect(hdc: w32.HDC, r: pane_sidebar.Rect, color: u32) void {
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    var rr = w32.RECT{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
    _ = w32.FillRect(hdc, &rr, brush);
}

/// `r`'s rounded outline, `width` thick, drawn inside it.
fn strokeRound(hdc: w32.HDC, r: pane_sidebar.Rect, radius: i32, color: u32, width: i32) void {
    const pen = w32.CreatePen(PS_INSIDEFRAME, width, color) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old_brush = w32.SelectObject(hdc, w32.GetStockObject(w32.NULL_BRUSH));
    defer _ = w32.SelectObject(hdc, old_brush);
    const old_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, old_pen);
    _ = w32.RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
}

const PS_INSIDEFRAME: i32 = 6;

fn fillRound(hdc: w32.HDC, r: pane_sidebar.Rect, radius: i32, color: u32) void {
    const rgn = w32.CreateRoundRectRgn(r.left, r.top, r.right + 1, r.bottom + 1, 2 * radius, 2 * radius) orelse return;
    defer _ = w32.DeleteObject(rgn);
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    _ = w32.FillRgn(hdc, rgn, @ptrCast(brush));
}

fn rgb(c: color_math.Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

fn shade(c: color_math.Rgb, delta: i32) color_math.Rgb {
    return .{
        .r = icon_button.shadeChannel(c.r, delta),
        .g = icon_button.shadeChannel(c.g, delta),
        .b = icon_button.shadeChannel(c.b, delta),
    };
}

fn drawText(hdc: w32.HDC, text: []const u16, r: pane_sidebar.Rect, color: u32, flags: u32) void {
    if (text.len == 0) return;
    _ = w32.SetTextColor(hdc, color);
    var rr = w32.RECT{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
    _ = w32.DrawTextW(hdc, text.ptr, @intCast(text.len), &rr, flags | w32.DT_NOPREFIX | w32.DT_SINGLELINE);
}

fn glyph(hdc: w32.HDC, scale: f32, r: pane_sidebar.Rect, cp: u16, dip: f32, color: u32) void {
    _ = icon_button_paint.fontCodepoint(
        hdc,
        scale,
        .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom },
        cp,
        dip,
        color,
    );
}

fn paint(self: *PaneSidebar, hdc: w32.HDC, width: i32, height: i32) void {
    if (!self.paint_bare and self.column != null) {
        if (self.paintColumn(hdc, width, height)) return;
    }
    defer self.paintEdgeBar(hdc, width, height);
    if (!self.paint_bare and self.xfade != null) {
        if (self.paintTransition(hdc, width, height)) return;
    }
    self.paintFrame(hdc, width, height);
}

/// The edge's accent bar (T2265; Mac `SidePanelResizeHandle.gutterBar`): down
/// the middle of the band that drags it, half strength while hovered, full
/// while dragged, never after.
fn paintEdgeBar(self: *PaneSidebar, hdc: w32.HDC, width: i32, height: i32) void {
    const dragged = if (self.edge) |d| !d.gutter else false;
    const strength = gutter_bar.single(self.edge_hover, dragged);
    const band = if (strength != null) pane_sidebar.edgeBand(&self.currentLayout(), self.scale, self.elevated()) else null;
    const shown: ?gutter_bar.Strength = if (band != null) strength else null;
    if (!std.meta.eql(shown, self.edge_bar_logged)) {
        self.edge_bar_logged = shown;
        log.debug("pane sidebar edge bar {s}", .{if (shown) |v| @tagName(v) else "none"});
    }
    const b = band orelse return;
    const core = gutter_bar.barIn(.{ .left = b.left, .top = b.top, .right = b.right, .bottom = b.bottom }, .across_x, self.scale);
    const color = chrome_theme.accentOn(self.theme().bg, system_colors.accentCached());
    gutter_bar_dc.paintOn(hdc, core, .{ .left = 0, .top = 0, .right = width, .bottom = height }, color, self.scale, shown.?);
}

fn elevated(self: *const PaneSidebar) bool {
    return self.window.paneStyle() == .elevated;
}

/// Set (or clear) whether the pointer is over the edge, repainting on a
/// change.
fn setEdgeHover(self: *PaneSidebar, on: bool) void {
    if (on == self.edge_hover) return;
    self.edge_hover = on;
    // Debug-build oracle (the `divider hover=` idiom): a posted move's hover
    // is gone within a frame on a background desktop, often before a paint.
    // `rail` is the surface's name from when the hover-open card was the
    // other one (T2289); the scripts read the line as it was.
    log.debug("pane sidebar edge hover={s}", .{if (on) "rail" else "none"});
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn paintFrame(self: *PaneSidebar, hdc: w32.HDC, width: i32, height: i32) void {
    const t = self.theme();
    var l = self.currentLayout();
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    self.paint_marks = .{};
    self.paint_dirty = .{};
    self.paint_ms = w32.GetTickCount64();
    self.paint_motion = App.clientAreaAnimationsEnabled();
    // A drag over the column: the rows as they slide, the dragged one lifted
    // out (T2304). The layout itself - hit-testing, the drop geometry - stays
    // where the rows are laid out, so the drop index never chases them.
    const laid = l;
    self.paint_lifted = self.applyDragMotion(&l, self.paint_ms);
    defer self.paint_lifted = null;
    self.applyItemMotion(&l, self.paint_ms);
    defer {
        self.lifted_heads = .initEmpty();
        self.lifted_items = .initEmpty();
    }
    switch (l.mode) {
        .hidden => fillRect(hdc, .{ .right = width, .bottom = height }, rgb(t.bg)),
        .expanded => self.paintExpanded(hdc, &l, t),
        .mini => self.paintMini(hdc, &l, t),
    }
    if (l.mode != .hidden) self.paintHeld(hdc, &laid, height, t);
    if (l.mode == .expanded) self.paintHeldItem(hdc, &laid, t);
    self.marks = self.paint_marks;
    self.dirty = self.paint_dirty;
    if (self.paint_marks.moving(self.paint_motion)) self.armMotion();
}

// -------------------------------------------------------------------------
// Reorder motion (T2304; Mac `PaneSidebarShift`, `PaneSidebarRowDrag`)
// -------------------------------------------------------------------------

/// Where a live pane drag stands for this sidebar: the pane, and - when a
/// release now would land HERE - the list or tray index it would land at, as
/// the resolver counts it. `pointer_y` (screen) moves a row held by the
/// pointer, which only a drag of this sidebar's own row has.
pub const DragAt = struct {
    pane: *const PaneView,
    list: ?usize = null,
    stash: ?usize = null,
    pointer_y: ?i32 = null,
};

/// A pane drag moved (T2304): slide the rows to make room for it, and move
/// the held row with the pointer.
pub fn noteDrag(self: *PaneSidebar, at: DragAt) void {
    if (self.drag) |d| {
        const settling = if (d.held) |h| h.settle != null else false;
        if (d.pane != at.pane or settling) self.drag = null;
    }
    if (self.drag == null) self.drag = .{ .pane = at.pane };
    const d = &self.drag.?;
    if (d.held) |*h| if (at.pointer_y) |py| {
        var pt = w32.POINT{ .x = 0, .y = py };
        _ = w32.ScreenToClient(self.hwnd, &pt);
        h.dy = pt.y - h.press_y;
    };

    // The sequence: this window's list rows, the tray's header, its tray.
    const l = self.currentLayout();
    var seq: [pane_sidebar.max_items]usize = undefined;
    const q = self.dragSequence(&l, &seq);
    var in_list: ?usize = null;
    var in_tray: ?usize = null;
    for (seq[0..q.len], 0..) |ei, k| if (self.entries.items[ei].pane == at.pane) {
        if (k < q.list) in_list = k else in_tray = k - q.list;
    };
    const was = d.slide;
    d.slide = reorder.slide(
        q.list,
        in_list,
        in_tray,
        at.list,
        if (at.stash) |s| reorder.trayTargetWithout(s, in_tray) else null,
    );
    if (!std.meta.eql(was, d.slide)) {
        if (d.slide) |sl| {
            log.info("pane sidebar drag slide source={?d} target={?d} list={d}", .{ sl.source, sl.target, q.list });
        } else log.info("pane sidebar drag slide none", .{});
    }

    const now = w32.GetTickCount64();
    const animate = App.clientAreaAnimationsEnabled();
    const pitch: f64 = @floatFromInt(rowPitch(&l, seq[0..q.len]));
    const header_rows: i32 = if (d.slide) |sl| sl.rows(reorder.trayIndex(q.list, null)) else 0;
    d.header.retarget(@as(f64, @floatFromInt(header_rows)) * pitch, now, animate);
    for (seq[0..q.len], 0..) |ei, k| {
        const k_seq = if (k < q.list) k else reorder.trayIndex(q.list, k - q.list);
        const rows: i32 = if (d.slide) |sl| sl.rows(k_seq) else 0;
        const tw = shiftFor(d, self.entries.items[ei].pane) orelse continue;
        tw.retarget(@as(f64, @floatFromInt(rows)) * pitch, now, animate);
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.armReorderClock();
}

/// The entries of this window's list (`list` of them, in the list's order)
/// then of its tray, as indices into `entries`: the rows a drop here lands
/// among, and the ones that slide. A folded row has no place.
fn dragSequence(self: *PaneSidebar, l: *const pane_sidebar.Layout, out: []usize) struct { len: usize, list: usize } {
    var n: usize = 0;
    const count = @min(l.count, self.entries.items.len);
    for (0..count) |i| {
        const e = self.entries.items[i];
        if (!e.own or e.section != .grid or !l.shown(i) or n == out.len) continue;
        out[n] = i;
        n += 1;
    }
    const list = n;
    for (0..count) |i| {
        const e = self.entries.items[i];
        if (!e.own or e.section != .stashed or !l.shown(i) or n == out.len) continue;
        out[n] = i;
        n += 1;
    }
    return .{ .len = n, .list = list };
}

/// How far a row slides to make room: one row's place - from one row's top
/// to the next's, the gap between them included - else a row's height.
fn rowPitch(l: *const pane_sidebar.Layout, seq: []const usize) i32 {
    var best: i32 = 0;
    var k: usize = 1;
    while (k < seq.len) : (k += 1) {
        const d = l.items[seq[k]].top - l.items[seq[k - 1]].top;
        if (d > 0 and (best == 0 or d < best)) best = d;
    }
    if (best > 0) return best;
    return if (seq.len > 0) l.items[seq[0]].height() else 0;
}

/// The slide of `pane`'s row, made when first asked for.
fn shiftFor(d: *DragMotion, pane: *const PaneView) ?*reorder.Tween {
    for (d.shifts[0..d.shift_count]) |*s| if (s.pane == pane) return &s.tween;
    if (d.shift_count == d.shifts.len) return null;
    d.shifts[d.shift_count] = .{ .pane = pane, .tween = .{} };
    d.shift_count += 1;
    return &d.shifts[d.shift_count - 1].tween;
}

/// The drag ended - dropped or cancelled. Nothing slides back: the drop
/// re-lays the list out where the rows were drawn (Mac: no animation once the
/// drag ends). A held row glides from where it was drawn to where it lands,
/// read off the layout each frame, so it arrives at the place the drop gave
/// it whenever the roster catches up.
fn endDragMotion(self: *PaneSidebar) void {
    if (self.drag) |*d| {
        d.slide = null;
        d.shift_count = 0;
        d.header = .{};
        if (d.held) |*h| if (h.drawn_top) |top| if (h.settle == null) {
            h.settle = .{ .from = top, .start_ms = w32.GetTickCount64() };
            log.info("pane sidebar row settle from={d}", .{top});
            _ = w32.InvalidateRect(self.hwnd, null, 0);
            self.armReorderClock();
            return;
        };
        self.drag = null;
        _ = w32.InvalidateRect(self.hwnd, null, 0);
    }
}

/// Slide `l`'s rows (and the tray's header) where the drag has them at
/// `now`, and answer the row it lifts out: the dragged pane's own, while it
/// is held, or while a drop here would take it from its place.
fn applyDragMotion(self: *PaneSidebar, l: *pane_sidebar.Layout, now: u64) ?usize {
    const d = if (self.drag) |*x| x else return null;
    const count = @min(l.count, self.entries.items.len);
    const lifts = d.held != null or (if (d.slide) |sl| sl.source != null else false);
    var lifted: ?usize = null;
    for (0..count) |i| {
        const pane = self.entries.items[i].pane;
        if (pane == d.pane and lifts) lifted = i;
        for (d.shifts[0..d.shift_count]) |s| if (s.pane == pane) {
            const dy: i32 = @intFromFloat(@round(s.tween.at(now)));
            l.items[i].top += dy;
            l.items[i].bottom += dy;
        };
    }
    const hy: i32 = @intFromFloat(@round(d.header.at(now)));
    if (hy != 0 and !l.outline) {
        if (l.section_rule) |*r| {
            r.top += hy;
            r.bottom += hy;
        }
        if (l.stashed_caption) |*r| {
            r.top += hy;
            r.bottom += hy;
        }
    }
    return lifted;
}

/// The held row, over everything else: at its laid-out place moved by the
/// pointer's travel, up or down only and kept inside the bar, on a solid
/// backing with a shadow - or, let go, gliding to where it landed while the
/// lift fades (Mac `ghost`).
fn paintHeld(self: *PaneSidebar, hdc: w32.HDC, laid: *const pane_sidebar.Layout, height: i32, t: Theme) void {
    const d = if (self.drag) |*x| x else return;
    const h = if (d.held) |*x| x else return;
    const count = @min(laid.count, self.entries.items.len);
    const i = for (0..count) |k| {
        if (self.entries.items[k].pane == d.pane) break k;
    } else return;
    const r = laid.items[i];
    if (r.width() <= 0) return;
    const clip = laid.viewport.height() > 0;
    const lo = if (clip) laid.viewport.top else 0;
    const hi = if (clip) laid.viewport.bottom else height;
    const top = if (h.settle) |s|
        reorder.settleTop(s.from, r.top, self.paint_ms -| s.start_ms)
    else
        reorder.heldTop(r.top, h.dy, r.height(), lo, hi);
    if (h.drawn_top != top) log.debug("pane sidebar row held top={d}", .{top});
    h.drawn_top = top;
    const lift: f64 = if (h.settle) |s| 1 - transition.progress(self.paint_ms -| s.start_ms, reorder.settle_ms) else 1;
    const at: pane_sidebar.Rect = .{ .left = r.left, .top = top, .right = r.right, .bottom = top + r.height() };
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    if (clip) _ = w32.IntersectClipRect(hdc, laid.viewport.left, laid.viewport.top, laid.viewport.right, laid.viewport.bottom);
    if (lift > 0) {
        const radius = pane_sidebar.px(toc.row_corner_dip, self.scale);
        const g = reorder.liftInset(at.width(), at.height());
        const back: pane_sidebar.Rect = .{
            .left = at.left - g.x,
            .top = at.top - g.y,
            .right = at.right + g.x,
            .bottom = at.bottom + g.y,
        };
        self.paintHeldShadow(hdc, back, radius, lift);
        const solid = color_math.mix(t.surface, t.ink, reorder.backing_ink);
        fillRound(hdc, back, radius, rgb(color_math.mix(t.surface, solid, lift)));
    }
    if (laid.mode == .mini)
        self.paintTile(hdc, i, at, false, self.isEmphasized(), t)
    else
        self.paintRow(hdc, laid, i, at, false, self.isEmphasized(), t);
}

/// The held row's shadow (Mac: radius 6 pt, 3 pt down, 0.3 black), blended
/// over whatever lies under it at `strength` of its full weight.
fn paintHeldShadow(self: *PaneSidebar, hdc: w32.HDC, r: pane_sidebar.Rect, radius: i32, strength: f64) void {
    const blur = pane_sidebar.px(reorder.shadow_radius_dip, self.scale);
    const dy = pane_sidebar.px(reorder.shadow_y_dip, self.scale);
    const box: pane_sidebar.Rect = .{ .left = r.left - blur, .top = r.top - blur + dy, .right = r.right + blur, .bottom = r.bottom + blur + dy };
    const w = box.width();
    const bh = box.height();
    if (w <= 0 or bh <= 0) return;
    const dib = Dib32.create(hdc, w, bh) orelse return;
    defer dib.destroy();
    const uw: usize = @intCast(w);
    for (0..@intCast(bh)) |y| {
        for (dib.pixels[y * uw ..][0..uw], 0..) |*p, x| {
            const dist = roundRectDistance(@as(i32, @intCast(x)) - blur, @as(i32, @intCast(y)) - blur, r.width(), r.height(), radius);
            const a = reorder.shadowAlpha(dist, @floatFromInt(blur)) * strength;
            // Black, premultiplied: only the alpha.
            p.* = @as(u32, @intFromFloat(@round(std.math.clamp(a, 0, 1) * 255))) << 24;
        }
    }
    _ = w32.AlphaBlend(hdc, box.left, box.top, w, bh, dib.dc, 0, 0, w, bh, .{
        .SourceConstantAlpha = 255,
        .AlphaFormat = w32.AC_SRC_ALPHA,
    });
}

/// How far pixel (`x`, `y`) lies outside a `w` x `h` box with corners rounded
/// to `radius` (0 inside it).
fn roundRectDistance(x: i32, y: i32, w: i32, h: i32, radius: i32) f64 {
    const fx = @as(f64, @floatFromInt(x)) + 0.5;
    const fy = @as(f64, @floatFromInt(y)) + 0.5;
    const rr: f64 = @floatFromInt(@max(radius, 0));
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    // From the inner box the corners are drawn round, less the radius.
    const dx = @max(@max(rr - fx, fx - (fw - rr)), 0);
    const dy = @max(@max(rr - fy, fy - (fh - rr)), 0);
    return @max(@sqrt(dx * dx + dy * dy) - rr, 0);
}

fn armReorderClock(self: *PaneSidebar) void {
    if (self.reorder_armed) return;
    if (!self.reorderMoving(w32.GetTickCount64())) return;
    if (w32.SetTimer(self.hwnd, TIMER_REORDER, reorder.frame_ms, null) == 0) return;
    self.reorder_armed = true;
}

fn stopReorderClock(self: *PaneSidebar) void {
    if (!self.reorder_armed) return;
    _ = w32.KillTimer(self.hwnd, TIMER_REORDER);
    self.reorder_armed = false;
}

/// Whether anything of the drag's motion is still on its way at `now`.
fn reorderMoving(self: *PaneSidebar, now: u64) bool {
    if (self.item_drag) |*d| {
        if (d.settle) |st| if (now -| st.start_ms < reorder.settle_ms) return true;
        if (d.join_in) |f| if (now -| f.start_ms < join_fade_ms) return true;
        if (d.join_out) |f| if (now -| f.start_ms < join_fade_ms) return true;
        for (d.shifts[0..d.count]) |tw| if (!tw.done(now)) return true;
        if (d.settle != null) return false;
    }
    const d = self.drag orelse return false;
    if (d.held) |h| if (h.settle) |s| return now -| s.start_ms < reorder.settle_ms;
    if (!d.header.done(now)) return true;
    for (d.shifts[0..d.shift_count]) |s| if (!s.tween.done(now)) return true;
    return false;
}

/// A frame of the reorder motion: repaint, and stop the clock - and let a
/// settled row back into the list - once nothing moves.
fn onReorderTick(self: *PaneSidebar) void {
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    if (self.reorderMoving(w32.GetTickCount64())) return;
    self.stopReorderClock();
    if (self.drag) |d| if (d.held) |h| if (h.settle != null) {
        log.info("pane sidebar row settled", .{});
        self.drag = null;
    };
    if (self.item_drag) |d| if (d.settle != null) self.finishItemDrag();
}

// -------------------------------------------------------------------------
// Reordering windows and groups (T2337; Mac `PaneSidebarItemDrag`)
// -------------------------------------------------------------------------

/// Whether a line of group `g` belongs to the item keyed `key`: a project's
/// header, windows and panes all do; a window's own header and panes do.
/// `head` is the line's kind, null for a pane row.
fn belongs(g: *const Group, key: []const u8, head: ?pane_sidebar.HeadKind) bool {
    if (window_order.isProject(key)) return std.mem.eql(u8, g.pkey.slice(), key);
    if (head) |k| if (k != .window) return false;
    return std.mem.eql(u8, g.wkey.slice(), key);
}

/// Which of the drag's siblings a line of group `g` belongs to. In a window
/// drag (T2338) every row is its own: a project's header is its row, and a
/// window's header and panes are the window's.
fn itemSibling(d: *const ItemDrag, g: *const Group, head: ?pane_sidebar.HeadKind) ?usize {
    if (d.cross) {
        const header = head != null and head.? == .project;
        const key = if (header) g.pkey.slice() else g.wkey.slice();
        for (d.siblings[0..d.count], 0..) |*k, j| {
            if (d.row_header.isSet(j) == header and std.mem.eql(u8, k.slice(), key)) return j;
        }
        return null;
    }
    for (d.siblings[0..d.count], 0..) |*k, j| {
        if (belongs(g, k.slice(), head)) return j;
    }
    return null;
}

/// The item keyed `key` as laid out in `l`: its header and every row under
/// it. Null when nothing of it is laid out (its window just closed).
fn itemRect(self: *const PaneSidebar, l: *const pane_sidebar.Layout, key: []const u8) ?pane_sidebar.Rect {
    var r: ?pane_sidebar.Rect = null;
    for (l.heads[0..l.head_count]) |hd| {
        if (hd.index >= self.groups.items.len) continue;
        if (!belongs(&self.groups.items[hd.index], key, hd.kind)) continue;
        r = unionRect(r, hd.rect);
    }
    const count = @min(l.count, self.entries.items.len);
    for (0..count) |i| {
        if (!l.shown(i)) continue;
        const gi = self.entries.items[i].group;
        if (gi >= self.groups.items.len) continue;
        if (!belongs(&self.groups.items[gi], key, null)) continue;
        r = unionRect(r, l.items[i]);
    }
    return r;
}

/// Project `key`'s header as laid out in `l`, alone.
fn headRect(self: *const PaneSidebar, l: *const pane_sidebar.Layout, key: []const u8) ?pane_sidebar.Rect {
    for (l.heads[0..l.head_count]) |hd| {
        if (hd.kind != .project or hd.index >= self.groups.items.len) continue;
        if (std.mem.eql(u8, self.groups.items[hd.index].pkey.slice(), key)) return hd.rect;
    }
    return null;
}

fn unionRect(a: ?pane_sidebar.Rect, b: pane_sidebar.Rect) pane_sidebar.Rect {
    const x = a orelse return b;
    return .{ .left = @min(x.left, b.left), .top = @min(x.top, b.top), .right = @max(x.right, b.right), .bottom = @max(x.bottom, b.bottom) };
}

/// The siblings' extents in `l`, by index. False when the dragged item has
/// none; a sibling that has none (closed mid-drag) stands in as an empty
/// span where the one before it ended, so it is passed with that one.
fn siblingSpans(self: *const PaneSidebar, l: *const pane_sidebar.Layout, d: *const ItemDrag, out: []window_order.Span) bool {
    var prev_bottom: ?i32 = null;
    for (d.siblings[0..d.count], 0..) |*k, j| {
        // A window drag's group row is its header alone (T2338).
        const rect = if (d.cross and d.row_header.isSet(j)) self.headRect(l, k.slice()) else self.itemRect(l, k.slice());
        if (rect) |r| {
            out[j] = .{ .top = r.top, .bottom = r.bottom };
            prev_bottom = r.bottom;
        } else {
            if (j == d.source) return false;
            const y = prev_bottom orelse 0;
            out[j] = .{ .top = y, .bottom = y };
        }
    }
    return true;
}

/// A press on a window row or a project header that has travelled past the
/// drag threshold picks that item up (Mac `PaneSidebarItemDragView`), in the
/// expanded all-windows list. While a search filters it, it moves among the
/// items shown, and those the search hides keep their places
/// (`window_order.moving`). The chevron, + and x are not drag sources (they
/// are other hits). True when it did.
fn maybeStartItemDrag(self: *PaneSidebar, hwnd: w32.HWND, x: i32, y: i32) bool {
    if (self.item_drag != null or w32.GetCapture() != hwnd) return false;
    const k = switch (self.pressed) {
        .head => |k| k,
        else => return false,
    };
    if (!drop_highlight.exceedsThreshold(x - self.press_x, y - self.press_y, drop_highlight.thresholdPx(self.scale))) return false;
    if (!self.all_windows or self.mode != .expanded) return false;
    const l = self.currentLayout();
    if (!l.outline or k >= l.head_count) return false;
    const hd = l.heads[k];
    if (hd.index >= self.groups.items.len) return false;
    const g = self.groups.items[hd.index];
    var d: ItemDrag = .{
        .key = if (hd.kind == .project) g.pkey else g.wkey,
        .kind = hd.kind,
        .pointer = y,
        .grab = self.press_y - hd.rect.top,
        .grabbed_top = hd.rect.top,
        .top = hd.rect.top,
    };
    if (hd.kind == .window) {
        // A window drag reads the whole list as rows (T2338, Mac
        // `listRows`): each group's header, its windows, the lone windows -
        // what the list shows, a search included.
        d.cross = true;
        for (l.heads[0..l.head_count]) |o| {
            if (o.index >= self.groups.items.len or d.count == d.siblings.len) continue;
            const og = &self.groups.items[o.index];
            d.siblings[d.count] = if (o.kind == .project) og.pkey else og.wkey;
            d.row_pkey[d.count] = og.pkey;
            d.row_header.setValue(d.count, o.kind == .project);
            d.count += 1;
        }
    } else for (self.groups.items, 0..) |*o, gi| {
        // A group's siblings, in the list's order: the top level - each
        // group once, by its first window, and every lone window.
        if (d.count == d.siblings.len) break;
        if (o.pkey.len == 0) {
            d.siblings[d.count] = o.wkey;
        } else if (gi == 0 or !std.mem.eql(u8, self.groups.items[gi - 1].pkey.slice(), o.pkey.slice())) {
            d.siblings[d.count] = o.pkey;
        } else continue;
        d.count += 1;
    }
    d.source = for (d.siblings[0..d.count], 0..) |*sk, j| {
        if (std.mem.eql(u8, sk.slice(), d.key.slice())) break j;
    } else return false;
    d.target = d.source;

    self.pressed = .none;
    self.hover = .none;
    self.syncHoverTint();
    // Every group folds to its header for a group drag, every window to its
    // row for a window drag, so each is one line high and easy to place.
    if (hd.kind == .project) {
        var projects: [pane_sidebar.max_heads]u64 = undefined;
        var np: usize = 0;
        for (d.siblings[0..d.count]) |*sk| {
            if (!window_order.isProject(sk.slice())) continue;
            projects[np] = projectKey(sk.slice()[window_order.project_prefix.len..]);
            np += 1;
        }
        d.folds_before = shared.foldProjects(self.alloc, projects[0..np]);
    } else d.unfolded_before = shared.foldWindows(self.alloc);
    self.stopReorderClock();
    self.item_drag = d;
    self.join_logged = false;
    self.published();
    log.info("pane sidebar item drag start kind={s} key={s} {s}={d} source={d}", .{ @tagName(hd.kind), d.key.slice(), if (d.cross) "rows" else "siblings", d.count, d.source });
    self.refresh();
    self.itemRelayout();
    return true;
}

/// The pointer or the layout moved: the item follows the pointer, kept in
/// its list, the index follows the item, and the others slide to make room.
fn itemRelayout(self: *PaneSidebar) void {
    const d = if (self.item_drag) |*x| x else return;
    if (d.settle != null) return;
    const l = self.currentLayout();
    var frames: [pane_sidebar.max_heads]window_order.Span = undefined;
    if (!self.siblingSpans(&l, d, &frames)) return self.endItemDrag(false);
    const f = frames[0..d.count];
    if (d.cross) return self.crossRelayout(d, f);
    const top = window_order.clamp(d.pointer - d.grab, d.source, f, d.grabbed_top);
    const to = window_order.target(top, d.source, f);
    const pitch: f64 = @floatFromInt(window_order.pitch(d.source, f));
    const now = w32.GetTickCount64();
    const animate = App.clientAreaAnimationsEnabled();
    for (0..d.count) |j| {
        if (j == d.source) continue;
        const rows = pane_sidebar_order.shift(j, d.source, to);
        d.shifts[j].retarget(@as(f64, @floatFromInt(rows)) * pitch, now, animate);
    }
    if (to != d.target) log.info("pane sidebar item drag target={d}", .{to});
    d.target = to;
    if (top != d.top) log.debug("pane sidebar item held top={d}", .{top});
    d.top = top;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.armReorderClock();
}

/// A window drag's relayout (T2338, Mac `relayoutRows`): it follows the
/// pointer anywhere in the list, every row slides on its own, and the slot
/// and destination follow it - the header of a group it would join, not its
/// own, outlined.
fn crossRelayout(self: *PaneSidebar, d: *ItemDrag, f: []const window_order.Span) void {
    // Grabbed below its row's middle, it is held by that middle: folded to
    // its row, it would otherwise hang above the pointer.
    const grab = @min(d.grab, @divTrunc(f[d.source].height(), 2));
    const top = window_order.clamp(d.pointer - grab, d.source, f, d.grabbed_top);
    d.pitch = window_order.pitch(d.source, f);
    var rows: [pane_sidebar.max_heads]cross_drop.Row = undefined;
    for (f, 0..) |span, j| rows[j] = .{ .project = d.rowProject(j), .header = d.row_header.isSet(j), .span = span };
    const r = cross_drop.resolve(rows[0..d.count], d.source, d.pitch, top);
    const now = w32.GetTickCount64();
    const animate = App.clientAreaAnimationsEnabled();
    const pitch: f64 = @floatFromInt(d.pitch);
    for (0..d.count) |j| {
        if (j == d.source) continue;
        const n = pane_sidebar_order.shift(j, d.source, r.slot);
        d.shifts[j].retarget(@as(f64, @floatFromInt(n)) * pitch, now, animate);
    }
    if (r.slot != d.target) log.info("pane sidebar item drag target={d}", .{r.slot});
    d.target = r.slot;
    if (top != d.top) log.debug("pane sidebar item held top={d}", .{top});
    d.top = top;
    // The project's row: its header, else (a search hides it) any row of it.
    const dest: ItemDrag.CrossDest = switch (r.dest) {
        .top_level => |i| .{ .top_level = i },
        .group => |g| .{ .group = .{ .row = projectRow(d, g.project) orelse d.source, .index = g.index } },
    };
    if (d.dest == null or !std.meta.eql(d.dest.?, dest)) {
        switch (r.dest) {
            .group => |g| log.info("pane sidebar item drag dest=group:{s}@{d}", .{ g.project, g.index }),
            .top_level => |i| log.info("pane sidebar item drag dest=top@{d}", .{i}),
        }
    }
    d.dest = dest;
    // Joining a group it is not in already: that group's header says so.
    const joining: ?usize = switch (dest) {
        .group => |g| if (sameName(d.destProject(dest), d.ownProject())) null else g.row,
        .top_level => null,
    };
    const was: ?usize = if (d.join_in) |j| j.row else null;
    if (!std.meta.eql(joining, was)) {
        if (d.join_in) |j| d.join_out = .{ .row = j.row, .start_ms = now };
        d.join_in = if (joining) |row| .{ .row = row, .start_ms = now } else null;
        if (!animate) {
            if (d.join_in) |*j| j.start_ms = now -| join_fade_ms;
            d.join_out = null;
        }
        log.info("pane sidebar item drag join={s}", .{if (joining) |row| d.rowProject(row) orelse "?" else "none"});
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.armReorderClock();
}

/// The first row of the drag naming group `project`: its header row first.
fn projectRow(d: *const ItemDrag, project: []const u8) ?usize {
    var any: ?usize = null;
    for (0..d.count) |j| {
        const p = d.rowProject(j) orelse continue;
        if (!std.mem.eql(u8, p, project)) continue;
        if (d.row_header.isSet(j)) return j;
        if (any == null) any = j;
    }
    return any;
}

fn sameName(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, x, y);
}

/// The join outline's strength on project header row `row` at `now`: 0 when
/// it is not outlined.
fn joinAlpha(d: *const ItemDrag, row: usize, now: u64) f64 {
    if (d.settle != null) return 0;
    if (d.join_in) |j| if (j.row == row) return transition.progress(now -| j.start_ms, join_fade_ms);
    if (d.join_out) |j| if (j.row == row) {
        const p = transition.progress(now -| j.start_ms, join_fade_ms);
        return if (p >= 1) 0 else 1 - p;
    };
    return 0;
}

/// Let go - or, `commit` false, cancelled (Escape, the capture taken): the
/// order changes in every window's list, and the item glides from where it
/// was drawn to its place. Moved, nothing else slides: the new order is laid
/// out where the others were drawn. Unmoved, they ease back with it.
fn endItemDrag(self: *PaneSidebar, commit: bool) void {
    const d = if (self.item_drag) |*x| x else return;
    if (d.settle != null) return;
    const regroups = d.cross and commit and d.dest != null and !sameName(d.destProject(d.dest.?), d.ownProject());
    const moved = commit and (d.target != d.source or regroups);
    log.info("pane sidebar item drag end commit={} from={d} to={d}", .{ commit, d.source, if (moved) d.target else d.source });
    const now = w32.GetTickCount64();
    const animate = App.clientAreaAnimationsEnabled();
    for (d.shifts[0..d.count]) |*tw| {
        if (moved) tw.* = .{} else tw.retarget(0, now, animate);
    }
    d.settle = .{ .from = d.top, .start_ms = now };
    if (moved) {
        if (d.cross) self.placeWindow(d) else self.placeItem(d);
    }
    if (!animate) return self.finishItemDrag();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.armReorderClock();
}

/// Put the dragged item at its target among its siblings in the shared
/// order, store it, and lay the list out again (Mac
/// `placeInAllWindowsList`). The list only: nothing moves on screen.
fn placeItem(self: *PaneSidebar, d: *const ItemDrag) void {
    var without: [pane_sidebar.max_heads][]const u8 = undefined;
    var nw: usize = 0;
    for (d.siblings[0..d.count], 0..) |*k, j| {
        if (j == d.source) continue;
        without[nw] = k.slice();
        nw += 1;
    }
    // Every key the list has - every window's, whatever a search shows:
    // anything else in the order is a closed window, pruned now.
    var key_bufs: [pane_sidebar.max_heads * 2]window_order.Key = undefined;
    var existing: [pane_sidebar.max_heads * 2][]const u8 = undefined;
    const ne = self.allOrderKeys(&key_bufs, &existing);
    var cur_buf: [window_order.max_keys][]const u8 = undefined;
    const cur = shared.windowOrder(&cur_buf);
    var out: [window_order.max_keys][]const u8 = undefined;
    const n = window_order.moving(d.key.slice(), d.target, without[0..nw], cur, existing[0..ne], &out);
    if (shared.setWindowOrder(self.alloc, out[0..n])) {
        var saved: [window_order.max_keys][]const u8 = undefined;
        window_order.save(self.alloc, shared.windowOrder(&saved));
        log.info("pane sidebar window order saved keys={d}", .{n});
    }
    self.published();
    self.refresh();
}

/// A window let go (T2338, Mac `endWindow`): moved among its own group's
/// windows (or the top level) it only reorders; into another group, or out
/// of its own, it is renamed to say so - `<project>: <name>`, or its name
/// alone, pinned as Change Window Title pins it - and lands where it was let
/// go, in every window's list.
fn placeWindow(self: *PaneSidebar, d: *const ItemDrag) void {
    const dest = d.dest orelse return;
    const app = self.window.app;
    const project = d.destProject(dest);
    // Its new siblings, in the list's order, without it: the group's
    // windows, or the top level - each group once, and every lone window.
    var among: [pane_sidebar.max_heads][]const u8 = undefined;
    var na: usize = 0;
    const gkey: window_order.Key = if (project) |p| window_order.projectKey(p) else .{};
    for (self.groups.items, 0..) |*o, gi| {
        if (na == among.len) break;
        const dragged = std.mem.eql(u8, o.wkey.slice(), d.key.slice());
        if (project != null) {
            if (dragged or !std.mem.eql(u8, o.pkey.slice(), gkey.slice())) continue;
            among[na] = o.wkey.slice();
        } else if (o.pkey.len == 0) {
            if (dragged) continue;
            among[na] = o.wkey.slice();
        } else if (gi == 0 or !std.mem.eql(u8, self.groups.items[gi - 1].pkey.slice(), o.pkey.slice())) {
            among[na] = o.pkey.slice();
        } else continue;
        na += 1;
    }
    const index = switch (dest) {
        .group => |g| g.index,
        .top_level => |i| i,
    };
    if (!sameName(project, d.ownProject())) {
        // Its own name - a grouped window's part after `<project>: ` - under
        // its new group's, or alone.
        for (self.groups.items) |*o| {
            if (!std.mem.eql(u8, o.wkey.slice(), d.key.slice())) continue;
            if (!app.hasWindow(o.window) or o.tab >= o.window.tab_count) break;
            var nb: [name_cap]u8 = undefined;
            const name = groupName(o.window, o.tab, &nb);
            var tb: [name_cap + 64]u8 = undefined;
            // Copied before the pin replaces the title it was read from.
            const title = rename_rules.groupTitle(&tb, project orelse "", ownLabel(name));
            log.info("pane sidebar window regrouped from={s} to={s} title={s}", .{ d.ownProject() orelse "", project orelse "", title });
            pinWindowName(o.window, o.tab, title);
            break;
        }
    }
    var key_bufs: [pane_sidebar.max_heads * 2]window_order.Key = undefined;
    var existing: [pane_sidebar.max_heads * 2][]const u8 = undefined;
    const ne = self.allOrderKeys(&key_bufs, &existing);
    var cur_buf: [window_order.max_keys][]const u8 = undefined;
    const cur = shared.windowOrder(&cur_buf);
    var out: [window_order.max_keys][]const u8 = undefined;
    const n = window_order.moving(d.key.slice(), index, among[0..na], cur, existing[0..ne], &out);
    if (shared.setWindowOrder(self.alloc, out[0..n])) {
        var saved: [window_order.max_keys][]const u8 = undefined;
        window_order.save(self.alloc, shared.windowOrder(&saved));
        log.info("pane sidebar window order saved keys={d}", .{n});
    }
    self.published();
    // Any window rename redraws every sidebar (Mac `PaneRoster.changed`).
    refreshScopes(app.windows.items, null);
    self.refresh();
}

/// Every key of the all-windows list, unfiltered (Mac
/// `PaneSidebarWindowGrouping.keys`): each window's, and each project's
/// once. Keys go into `bufs`; returns how many were written to `out`.
fn allOrderKeys(self: *const PaneSidebar, bufs: []window_order.Key, out: [][]const u8) usize {
    var n: usize = 0;
    for (self.window.app.windows.items) |w| {
        if (w.closing or w.is_quick_terminal) continue;
        for (0..w.tab_count) |t| {
            if (n + 2 > out.len) return n;
            bufs[n] = window_order.windowKey(&w.tab_uuid[t]);
            out[n] = bufs[n].slice();
            n += 1;
            var name_buf: [name_cap]u8 = undefined;
            const split = outline.splitWindowTitle(groupName(w, t, &name_buf)) orelse continue;
            const pk = window_order.projectKey(split.project);
            const seen = for (out[0..n]) |k| {
                if (std.mem.eql(u8, k, pk.slice())) break true;
            } else false;
            if (seen) continue;
            bufs[n] = pk;
            out[n] = bufs[n].slice();
            n += 1;
        }
    }
    return n;
}

/// The glide is over (or the window is going): the drag ends, the folds it
/// took come back as they were, and every row re-syncs from the pointer.
fn finishItemDrag(self: *PaneSidebar) void {
    var d = self.item_drag orelse return;
    self.item_drag = null;
    if (d.folds_before) |*b| shared.restoreFolds(self.alloc, .projects, b);
    if (d.unfolded_before) |*b| shared.restoreFolds(self.alloc, .windows, b);
    self.published();
    log.info("pane sidebar item drag settled", .{});
    self.refresh();
    var pt: w32.POINT = undefined;
    const over = self.pointerOn() and w32.GetCursorPos_(&pt) != 0 and w32.ScreenToClient(self.hwnd, &pt) != 0;
    self.setHover(if (over) self.hitAt(pt.x, pt.y) else .none);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// Escape (routed by the app's run loop, which sees the key whichever pane
/// has the keyboard): cancel a held item. True when there was one.
pub fn cancelItemDrag(self: *PaneSidebar) bool {
    const d = self.item_drag orelse return false;
    if (d.settle != null) return false;
    self.endItemDrag(false);
    _ = w32.ReleaseCapture();
    return true;
}

/// Slide `l`'s lines where the drag has them at `now`, and mark the dragged
/// item's lines for `paintHeldItem` to draw instead. The sticky header and
/// the hairlines stand down while an item is held: neither follows a slide.
fn applyItemMotion(self: *PaneSidebar, l: *pane_sidebar.Layout, now: u64) void {
    const d = if (self.item_drag) |*x| x else return;
    l.sticky = null;
    l.rule_count = 0;
    for (l.heads[0..l.head_count], 0..) |*hd, k| {
        if (hd.index >= self.groups.items.len) continue;
        const j = itemSibling(d, &self.groups.items[hd.index], hd.kind) orelse continue;
        if (j == d.source) {
            self.lifted_heads.set(k);
            continue;
        }
        const dy: i32 = @intFromFloat(@round(d.shifts[j].at(now)));
        hd.rect.top += dy;
        hd.rect.bottom += dy;
        hd.chevron.top += dy;
        hd.chevron.bottom += dy;
    }
    const count = @min(l.count, self.entries.items.len);
    for (0..count) |i| {
        if (!l.shown(i)) continue;
        const gi = self.entries.items[i].group;
        if (gi >= self.groups.items.len) continue;
        const j = itemSibling(d, &self.groups.items[gi], null) orelse continue;
        if (j == d.source) {
            self.lifted_items.set(i);
            continue;
        }
        const dy: i32 = @intFromFloat(@round(d.shifts[j].at(now)));
        l.items[i].top += dy;
        l.items[i].bottom += dy;
    }
}

/// The held item over everything else (Mac `PaneSidebarItemShift`'s lift):
/// its header and rows moved to where the pointer has it, on a solid backing
/// with a shadow - or, let go, gliding to its laid-out place while the lift
/// fades. The dragged header keeps its hover controls.
fn paintHeldItem(self: *PaneSidebar, hdc: w32.HDC, laid: *const pane_sidebar.Layout, t: Theme) void {
    const d = if (self.item_drag) |*x| x else return;
    const r = self.itemRect(laid, d.key.slice()) orelse return;
    const top = if (d.settle) |st| reorder.settleTop(st.from, r.top, self.paint_ms -| st.start_ms) else d.top;
    const dy = top - r.top;
    const lift: f64 = if (d.settle) |st| 1 - transition.progress(self.paint_ms -| st.start_ms, reorder.settle_ms) else 1;
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    const vp = laid.viewport;
    if (vp.height() > 0) _ = w32.IntersectClipRect(hdc, vp.left, vp.top, vp.right, vp.bottom);
    if (lift > 0) {
        const radius = pane_sidebar.px(toc.row_corner_dip, self.scale);
        const g = reorder.liftInset(r.width(), r.height());
        const back: pane_sidebar.Rect = .{ .left = r.left - g.x, .top = top - g.y, .right = r.right + g.x, .bottom = top + r.height() + g.y };
        self.paintHeldShadow(hdc, back, radius, lift);
        const solid = color_math.mix(t.surface, t.ink, reorder.backing_ink);
        fillRound(hdc, back, radius, rgb(color_math.mix(t.surface, solid, lift)));
    }
    const hover_was = self.hover;
    defer self.hover = hover_was;
    for (laid.heads[0..laid.head_count], 0..) |hd, k| {
        if (hd.index >= self.groups.items.len) continue;
        if (!belongs(&self.groups.items[hd.index], d.key.slice(), hd.kind)) continue;
        var moved = hd;
        moved.rect.top += dy;
        moved.rect.bottom += dy;
        moved.chevron.top += dy;
        moved.chevron.bottom += dy;
        self.hover = .{ .head = k };
        self.paintHead(hdc, moved, k, self.groups.items[hd.index], t);
    }
    self.hover = hover_was;
    const count = @min(laid.count, self.entries.items.len);
    for (0..count) |i| {
        if (!laid.shown(i)) continue;
        const gi = self.entries.items[i].group;
        if (gi >= self.groups.items.len or !belongs(&self.groups.items[gi], d.key.slice(), null)) continue;
        var at = laid.items[i];
        at.top += dy;
        at.bottom += dy;
        self.paintRow(hdc, laid, i, at, false, self.isEmphasized(), t);
    }
}

// -------------------------------------------------------------------------
// Motion (T1843)
// -------------------------------------------------------------------------

/// Start the motion clock, if it is not already running. The logs keep
/// their `surface=rail` field from when the hover-open card had a clock of
/// its own (T2289); the scripts read the lines as they were.
fn armMotion(self: *PaneSidebar) void {
    if (self.anim_armed) return;
    if (w32.SetTimer(self.hwnd, TIMER_ANIM, motion.frame_ms, null) == 0) return;
    self.anim_armed = true;
    self.motion_frames = 0;
    self.motion_px = 0;
    self.motion_client_px = 0;
    const m = self.marks;
    log.info("pane sidebar motion on surface=rail busy={d}", .{m.busy});
}

/// How often a running motion clock re-reads the roster (`onMotionTick`).
const busy_poll_every_ms: u64 = 1000;

/// A motion frame: repaint while the last paint drew something that moves
/// and the window can be seen; otherwise stop. A paint that draws something
/// moving again re-arms it, so the clock never runs for a still column.
fn onMotionTick(self: *PaneSidebar) void {
    const hwnd = self.hwnd;
    const root = w32.GetAncestor(hwnd, w32.GA_ROOT);
    const seen = w32.IsWindowVisible(hwnd) != 0 and !(root != null and w32.IsIconic(root.?) != 0);
    if (seen and self.marks.moving(App.clientAreaAnimationsEnabled())) {
        // A progress report that lapses without a "done" stops being work
        // by the clock alone (T2279: busy includes the report lighting the
        // border), so re-read the roster now and then while a row sheens.
        // Cheap: it hashes and returns when nothing changed.
        const now = w32.GetTickCount64();
        if (now -| self.busy_poll_ms >= busy_poll_every_ms) {
            self.busy_poll_ms = now;
            self.refresh();
        }
        self.invalidateMoving();
        return;
    }
    _ = w32.KillTimer(hwnd, TIMER_ANIM);
    self.anim_armed = false;
    // The run's cost (T1925): `area` is the share of the column the frames
    // painted, in percent - near 100 is the whole sidebar every frame.
    const area = if (self.motion_client_px > 0) self.motion_px * 100 / self.motion_client_px else 0;
    log.info("pane sidebar motion off surface=rail frames={d} area={d}", .{ self.motion_frames, area });
}

/// A motion frame's repaint (T1925): the pills that move, where the last
/// paint drew them - or the whole column while anything else moves it too
/// (a glide, a list transition, a drag), or when the pills were not all
/// noted.
fn invalidateMoving(self: *PaneSidebar) void {
    if (!self.dirty.partial() or self.column != null or self.xfade != null or self.drag != null or self.item_drag != null) {
        _ = w32.InvalidateRect(self.hwnd, null, 0);
        return;
    }
    for (self.dirty.items()) |r| {
        const rc: w32.RECT = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
        _ = w32.InvalidateRect(self.hwnd, &rc, 0);
    }
}

// -------------------------------------------------------------------------
// List transitions (T1880)
// -------------------------------------------------------------------------

/// The column's size as its paints see it.
fn surfaceSize(self: *PaneSidebar) ?[2]i32 {
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &r) == 0 or r.right <= r.left or r.bottom <= r.top) return null;
    return .{ r.right - r.left, r.bottom - r.top };
}

/// Picture the panel as it is now, before a change to its list - or null
/// when the change should simply land: animations are off (Mac's Reduce
/// Motion), the column is not on screen, or it shows no list (the rail's
/// tiles). The picture is the frame as presented, so a switch made
/// mid-transition leaves from where the eye is.
fn snapshot(self: *PaneSidebar, kind: xf.Kind) ?xf.Xfade {
    if (!App.clientAreaAnimationsEnabled()) return null;
    if (w32.IsWindowVisible(self.hwnd) == 0) return null;
    const l = self.currentLayout();
    if (l.mode != .expanded) return null;
    const size = self.surfaceSize() orelse return null;
    const screen = w32.GetDC(null) orelse return null;
    defer _ = w32.ReleaseDC(null, screen);
    const d = Dib32.create(screen, size[0], size[1]) orelse return null;
    self.paint(d.dc, size[0], size[1]);
    _ = w32.GdiFlush();
    return .{ .kind = kind, .w = size[0], .h = size[1], .old = d };
}

/// Run `snap`, replacing any transition already running. The logs keep
/// their `surface=rail` field (see `armMotion`).
fn startTransition(self: *PaneSidebar, snap: ?xf.Xfade) void {
    var x = snap orelse return;
    self.dropTransition();
    if (w32.SetTimer(self.hwnd, TIMER_XFADE, transition.frame_ms, null) == 0) return x.deinit();
    x.start_ms = w32.GetTickCount64();
    self.xfade = x;
    log.info("pane sidebar transition {s} surface=rail ms={d}", .{ @tagName(x.kind), x.duration() });
}

/// Stop the transition, if one runs, without a repaint.
fn dropTransition(self: *PaneSidebar) void {
    if (self.xfade) |*x| x.deinit();
    self.xfade = null;
    _ = w32.KillTimer(self.hwnd, TIMER_XFADE);
}

fn onTransitionTick(self: *PaneSidebar) void {
    const x = self.xfade orelse {
        _ = w32.KillTimer(self.hwnd, TIMER_XFADE);
        return;
    };
    if (w32.GetTickCount64() -| x.start_ms >= x.duration()) {
        self.dropTransition();
        log.info("pane sidebar transition done surface=rail", .{});
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// One frame of the transition into `hdc`: the frame after the change
/// painted live, the material alone, and the picture from before, composed
/// by `transition`. False when there is nothing to compose - the transition
/// has run out or the surface changed size under it - and the plain frame is
/// painted instead. A fold whose head moved (the list re-scrolled under it)
/// is dropped the same way: the fold just lands.
fn paintTransition(self: *PaneSidebar, hdc: w32.HDC, w: i32, h: i32) bool {
    const x = &(self.xfade.?);
    const old = x.old orelse return false;
    const elapsed = w32.GetTickCount64() -| x.start_ms;
    if (x.w != w or x.h != h or elapsed >= x.duration()) {
        self.dropTransition();
        return false;
    }
    const p = transition.progress(elapsed, x.duration());
    const bg = Dib32.create(hdc, w, h) orelse return false;
    defer bg.destroy();
    const new = Dib32.create(hdc, w, h) orelse return false;
    defer new.destroy();
    const out = Dib32.create(hdc, w, h) orelse return false;
    defer out.destroy();
    // The material first, so the motion tally the live frame leaves is the
    // one that stands.
    self.paint_bare = true;
    self.paintFrame(bg.dc, w, h);
    self.paint_bare = false;
    self.paintFrame(new.dc, w, h);
    _ = w32.GdiFlush();
    const l = self.currentLayout();
    const vp = l.viewport;
    const bottom = if (vp.height() > 0) vp.bottom else l.height;
    switch (x.kind) {
        .scope => |to_all| transition.composeSlide(out.pixels, bg.pixels, old.pixels, new.pixels, w, h, .{
            .left = l.header.left,
            .top = l.header.bottom,
            .right = l.header.right,
            .bottom = bottom,
        }, p, to_all, pane_sidebar.px(transition.scope_slide_dip, self.scale)),
        .fold => |f| {
            const nb = scroll_mod.contentBottom(&l, vp.top);
            if (f.head >= l.head_count or l.heads[f.head].rect.bottom != f.y0 or l.scroll != f.scroll or nb == f.bottom) {
                log.info("pane sidebar transition fold lands: the list moved under it", .{});
                self.dropTransition();
                return false;
            }
            const opening = nb > f.bottom;
            transition.composeFold(
                out.pixels,
                bg.pixels,
                if (opening) new.pixels else old.pixels,
                if (opening) old.pixels else new.pixels,
                new.pixels,
                w,
                h,
                .{ .left = vp.left, .top = vp.top, .right = vp.right, .bottom = bottom },
                f.y0,
                if (opening) nb - f.bottom else f.bottom - nb,
                opening,
                p,
            );
        },
    }
    _ = w32.BitBlt(hdc, 0, 0, w, h, out.dc, 0, 0, w32.SRCCOPY);
    return true;
}

// -------------------------------------------------------------------------
// Collapse and expand (T2291)
// -------------------------------------------------------------------------

/// Picture the column as it is shown now, for a collapse or expand to leave
/// from - or null when the change should simply land: animations are off, or
/// the column is not on screen. Taken mid-glide, it is the frame as drawn, so
/// a second click glides back from where the eye is.
fn snapshotColumn(self: *PaneSidebar) ?xf.Column {
    if (!App.clientAreaAnimationsEnabled()) return null;
    if (w32.IsWindowVisible(self.hwnd) == 0) return null;
    const size = self.surfaceSize() orelse return null;
    const screen = w32.GetDC(null) orelse return null;
    defer _ = w32.ReleaseDC(null, screen);
    const d = Dib32.create(screen, size[0], size[1]) orelse return null;
    self.paint(d.dc, size[0], size[1]);
    _ = w32.GdiFlush();
    return .{ .from_w = size[0], .to_w = size[0], .h = size[1], .old = d };
}

/// Run collapse-or-expand `c` toward a column `to_w` wide, replacing any
/// glide or list transition already running. The column is put over the
/// grid for the length of it: Mac's sidebar is an overlay on the stage, so
/// the cards gliding over glide under it.
fn startColumn(self: *PaneSidebar, c: xf.Column, to_w: i32) void {
    var next = c;
    self.dropColumn();
    self.dropTransition();
    if (w32.SetTimer(self.hwnd, TIMER_COLUMN, transition.frame_ms, null) == 0) return next.deinit();
    next.start_ms = w32.GetTickCount64();
    next.to_w = to_w;
    if (std.process.parseEnvVarInt("GHOZTTY_SIDEBAR_COLUMN_MS", u32, 10)) |ms| {
        next.ms = ms;
    } else |_| {}
    self.column = next;
    // HWND_TOP is null: without SWP_NOZORDER, the top of the children.
    _ = w32.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE);
    log.info("pane sidebar column glide {s} from={d} to={d} ms={d}", .{ @tagName(self.mode), next.from_w, to_w, next.ms });
}

/// Stop the glide, if one runs, without placing or repainting.
fn dropColumn(self: *PaneSidebar) void {
    if (self.column) |*c| c.deinit();
    self.column = null;
    _ = w32.KillTimer(self.hwnd, TIMER_COLUMN);
}

/// A frame of the glide: the column a step wider or narrower and repainted;
/// once it is over, placed at its new width by the window, as any layout
/// places it.
fn onColumnTick(self: *PaneSidebar) void {
    const c = self.column orelse {
        _ = w32.KillTimer(self.hwnd, TIMER_COLUMN);
        return;
    };
    const now = w32.GetTickCount64();
    if (c.done(now)) {
        self.dropColumn();
        log.info("pane sidebar column glide done width={d}", .{c.to_w});
        self.window.syncPaneSidebar();
        _ = w32.InvalidateRect(self.hwnd, null, 0);
        return;
    }
    var cur: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &cur) == 0) return;
    const w = c.widthAt(now);
    if (w != cur.right - cur.left) {
        _ = w32.SetWindowPos(self.hwnd, null, 0, 0, w, cur.bottom - cur.top, w32.SWP_NOMOVE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// One frame of the glide into `hdc` (`w` x `h`, the column as wide as it is
/// drawn now): the frame it left fading out and the new mode's - painted
/// live, at the width it goes to - fading in, both cut at the column's edge
/// (`transition.composeColumn`). False when there is nothing to compose and
/// the plain frame is painted instead.
fn paintColumn(self: *PaneSidebar, hdc: w32.HDC, w: i32, h: i32) bool {
    const c = &(self.column.?);
    const old = c.old orelse return false;
    if (c.h != h or w <= 0 or h <= 0 or c.to_w <= 0) return false;
    const p = c.progress(w32.GetTickCount64());
    const new = Dib32.create(hdc, c.to_w, h) orelse return false;
    defer new.destroy();
    const under = Dib32.create(hdc, w, h) orelse return false;
    defer under.destroy();
    const out = Dib32.create(hdc, w, h) orelse return false;
    defer out.destroy();
    self.paintFrame(new.dc, c.to_w, h);
    self.paintEdgeBar(new.dc, c.to_w, h);
    _ = w32.GdiFlush();
    // What the window draws where neither card reaches: the desk in the
    // elevated style, else the terminal background.
    const t = self.theme();
    if (self.window.deskBackdrop()) |d| copyDesk(under.pixels, w, h, d, t.bg) else {
        @memset(under.pixels, (@as(u32, t.bg.r) << 16) | (@as(u32, t.bg.g) << 8) | t.bg.b);
    }
    transition.composeColumn(out.pixels, w, h, old.pixels, c.from_w, new.pixels, c.to_w, under.pixels, p);
    _ = w32.BitBlt(hdc, 0, 0, w, h, out.dc, 0, 0, w32.SRCCOPY);
    return true;
}

fn unrgb(c: u32) color_math.Rgb {
    return .{ .r = @truncate(c), .g = @truncate(c >> 8), .b = @truncate(c >> 16) };
}

/// `sheenLevel` for the pill drawn at `r`, noting `r` for the next motion
/// frame while its sheen moves (T1925).
fn sheenAt(self: *PaneSidebar, e: Entry, r: pane_sidebar.Rect) f64 {
    const before = self.paint_marks;
    const level = self.sheenLevel(e);
    const after = self.paint_marks;
    if (self.paint_motion and (after.busy != before.busy or after.fading != before.fading)) self.paint_dirty.add(r);
    return level;
}

/// A row or tile the paint's clip leaves out (T1925): drawn by nobody this
/// time, but tallied as if it were, so the motion clock, the next frame's
/// pills and the marks log see the whole column whatever was repainted.
/// `bell` is whether the drawing would have shown its bell dot.
fn tallyUnpainted(self: *PaneSidebar, e: Entry, r: pane_sidebar.Rect, bell: bool) void {
    _ = self.sheenAt(e, r);
    if (bell) self.paint_marks.bells += 1;
}

/// The paint's clip box in `hdc`, or null when it cannot be read (then
/// everything is drawn).
fn clipOf(hdc: w32.HDC) ?pane_sidebar.Rect {
    var cb: w32.RECT = undefined;
    if (w32.GetClipBox(hdc, &cb) == 0) return null;
    return .{ .left = cb.left, .top = cb.top, .right = cb.right, .bottom = cb.bottom };
}

/// How strongly pane `e`'s sheen shows right now, 0 to 1 (T2279, Mac
/// `busyFade`): it fades in as work starts and out as it stops, from
/// wherever it had got to. Tallies a sheen still fading, so the clock runs
/// until it settles.
fn sheenLevel(self: *PaneSidebar, e: Entry) f64 {
    const now = self.paint_ms;
    // A busy pane is tallied whatever its sheen's level, so the clock (and its
    // log) starts with the fade-in rather than a frame after it.
    if (e.busy) self.paint_marks.busy += 1;
    var free: ?usize = null;
    for (self.fades[0..self.fade_count], 0..) |*s, k| {
        if (s.pane == e.pane) {
            s.fade = s.fade.retarget(e.busy, now);
            if (!s.fade.settled(now)) self.paint_marks.fading += 1;
            return s.fade.level(now);
        }
        if (free == null and !s.fade.on and s.fade.settled(now)) free = k;
    }
    if (!e.busy) return 0;
    const k = free orelse blk: {
        // No slot to spare: shown at full strength, without the fade.
        if (self.fade_count == self.fades.len) return 1;
        self.fade_count += 1;
        break :blk self.fade_count - 1;
    };
    self.fades[k] = .{ .pane = e.pane, .fade = .{ .on = true, .since_ms = now } };
    self.paint_marks.fading += 1;
    return 0;
}

/// What lies over a pill's fill (T2279, T2309; Mac
/// `PaneSidebarTileSheenLayer` and `PaneSidebarRow.tileBorder`): while its
/// pane is busy, the sheen - a slow slanted drift, a faint slanted glint
/// crossing it right to left every 2s, and the hairline rim they sit in - at
/// `level` of its strength while it fades; and on a rail tile (`tile`) the
/// glassy rim lit from above, which a full row never has. Built as a
/// premultiplied-alpha bitmap the pill's size - zero outside its rounded
/// corners - and blended over whatever the pill sits on (the card's glass
/// included), under the pill's glyph and text. With motion off the sheen
/// goes entirely (Mac's Reduce Motion drops it the same way); a tile keeps
/// its rim, which is not motion. The rim fades with the rail on expand and
/// collapse because the rail's whole column crossfades
/// (`transition.composeColumn`), never snapping at the mode switch.
fn paintOverlay(self: *PaneSidebar, hdc: w32.HDC, r: pane_sidebar.Rect, radius: i32, level: f64, tile: ?motion.TileRim, t: Theme) void {
    const w = r.width();
    const h = r.height();
    if (w <= 0 or h <= 0) return;
    var o = motion.Overlay.init(
        @floatFromInt(w),
        @floatFromInt(h),
        @floatFromInt(radius),
        motion.rim_dip * @as(f64, self.scale),
        t.dark,
    );
    if (self.paint_motion and level > 0) o.busyAt(level, self.paint_ms);
    o.tile_rim = tile;
    if (!o.visible()) return;
    const dib = Dib32.create(hdc, w, h) orelse return;
    defer dib.destroy();
    const uw: usize = @intCast(w);
    for (0..@intCast(h)) |y| {
        for (dib.pixels[y * uw ..][0..uw], 0..) |*p, x| {
            const px = o.pixel(x, y);
            const a: u32 = @intFromFloat(@round(std.math.clamp(px.alpha, 0, 1) * 255));
            const c: u32 = @intFromFloat(@round(std.math.clamp(px.white, 0, px.alpha) * 255));
            p.* = (a << 24) | (c << 16) | (c << 8) | c;
        }
    }
    _ = w32.AlphaBlend(hdc, r.left, r.top, w, h, dib.dc, 0, 0, w, h, .{
        .SourceConstantAlpha = 255,
        .AlphaFormat = w32.AC_SRC_ALPHA,
    });
}

/// What a pane's pill drew its glyph on.
const Pill = struct { icon: pane_sidebar.Rect, under: color_math.Rgb };

/// A pane's pill - a full row's, or a rail tile's, which is the row without
/// its text (T2279, Mac 75dc046e3): the selection or hover fill and its
/// indicator, the busy sheen across it, and the pane kind's glyph in its hue
/// `text_inset` into the pill and centred on it - the same place in both
/// modes, so toggling the sidebar moves no icon. `indent` moves the content
/// of an outline row, never its fill. A rail `tile` also wears its glassy
/// rim (T2309), brighter under the pointer.
fn paintPill(self: *PaneSidebar, hdc: w32.HDC, r: pane_sidebar.Rect, e: Entry, indent: i32, hovered: bool, emphasized: bool, tile: bool, t: Theme) Pill {
    const radius = pane_sidebar.px(toc.row_corner_dip, self.scale);
    const sel = list_selection.rowPaint(t.surface, t.accent, .{
        .selected = e.selected,
        .focused = emphasized,
        .hovered = hovered,
        .focus_visible = false,
    });
    if (sel.fill) |f| fillRound(hdc, r, radius, rgb(f));
    if (sel.indicator) |c| {
        const bar = toc.selectionIndicator(r.height(), self.scale);
        fillRound(hdc, .{
            .left = r.left + bar.left,
            .top = r.top + bar.top,
            .right = r.left + bar.left + bar.width,
            .bottom = r.top + bar.top + bar.height,
        }, bar.radius, rgb(c));
    }
    self.paintOverlay(hdc, r, radius, self.sheenAt(e, r), if (tile) motion.tileRim(t.dark, hovered) else null, t);
    const under = sel.fill orelse t.surface;
    const icon_w = pane_sidebar.px(pane_sidebar.icon_dip, self.scale);
    const left = r.left + pane_sidebar.px(toc.text_inset_dip, self.scale) + indent;
    const top = r.top + @divTrunc(r.height() - self.metrics.title_h, 2);
    const icon_r: pane_sidebar.Rect = .{ .left = left, .top = top, .right = left + icon_w, .bottom = top + self.metrics.title_h };
    // The pane's own hue (T2278, Mac iconColor): full on the focused row and
    // a hovered one, a touch quieter elsewhere.
    glyph(hdc, self.scale, icon_r, e.icon, 12, self.hueInk(e, under, hovered, emphasized, t));
    return .{ .icon = icon_r, .under = under };
}

/// A stashed pane's bell (Mac: a 7 pt accent dot until it is restored).
fn paintBellDot(self: *PaneSidebar, hdc: w32.HDC, cx: i32, cy: i32, t: Theme) void {
    self.paint_marks.bells += 1;
    const d = @max(pane_sidebar.px(7, self.scale), 3);
    const dot: pane_sidebar.Rect = .{ .left = cx - @divTrunc(d, 2), .top = cy - @divTrunc(d, 2), .right = cx - @divTrunc(d, 2) + d, .bottom = cy - @divTrunc(d, 2) + d };
    fillRound(hdc, dot, @divTrunc(d, 2), rgb(t.accent));
}

/// A pane's mark ink (T2278, Mac `iconColor`): its hue, at full strength on
/// the focused row of a focused window and on a hovered one, quieter
/// elsewhere, over `under`.
fn hueInk(self: *const PaneSidebar, e: Entry, under: color_math.Rgb, hovered: bool, emphasized: bool, t: Theme) u32 {
    _ = self;
    const strong = (e.selected and emphasized) or hovered;
    return rgb(pane_hue.iconInk(pane_hue.color(e.hue, t.dark), under, strong));
}

/// The pane under the pointer in this sidebar, if any, takes its hue as a
/// tint (T2278, Mac `PaneSidebarHover`); the one that had it lets go. Called
/// after every hover change. Only this sidebar's own last target is cleared,
/// so another window's sidebar that just took the hover keeps it.
fn syncHoverTint(self: *PaneSidebar) void {
    const app = self.window.app;
    const want: ?Entry = switch (self.hover) {
        .item, .item_button, .item_close => |i| if (i < self.entries.items.len) self.entries.items[i] else null,
        else => null,
    };
    const pane: ?*const PaneView = if (want) |e| e.pane else null;
    if (pane == self.tint_pane) return;
    if (pane) |p| {
        const e = want.?;
        app.sidebar_hover_pane = p;
        app.sidebar_hover_color = pane_hue.color(e.hue, self.theme().dark);
        const c = app.sidebar_hover_color;
        log.info("pane sidebar hover tint index={d} rgb={d},{d},{d}", .{ e.hue, c.r, c.g, c.b });
    } else if (app.sidebar_hover_pane == self.tint_pane) {
        app.sidebar_hover_pane = null;
    }
    self.tint_pane = pane;
    for (app.windows.items) |w| w.updateHoverTints();
}

fn isEmphasized(self: *const PaneSidebar) bool {
    return w32.windowIsActive(w32.GetAncestor(self.hwnd, w32.GA_ROOT));
}

fn hoverIs(self: *const PaneSidebar, hit: pane_sidebar.Hit) bool {
    return std.meta.eql(self.hover, hit);
}

/// The design system's disabled glyph (§2.2): the foreground 40% of the way
/// toward the background, with no fill in any state.
const disabled_toward_bg: f64 = 0.4;

/// Whether a click on the toggle would do anything: the panel's always
/// collapses; the rail's expands only where the panel fits (Mac
/// `.disabled(!canExpand)`).
fn toggleEnabled(self: *const PaneSidebar) bool {
    return self.mode == .expanded or self.can_expand;
}

/// The collapse/expand toggle (T2289): the open-pane glyph on the rail, the
/// close-pane glyph on the panel - the glyph says which way it goes, as
/// Mac's outline/filled `.sidebar` does - on the same pixels in both.
fn paintToggle(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const enabled = self.toggleEnabled();
    const state: icon_button.State = if (!enabled or !self.hoverIs(.toggle))
        .normal
    else if (std.meta.eql(self.pressed, pane_sidebar.Hit.toggle)) .pressed else .hover;
    if (icon_button.paintsFill(state)) {
        const inset = pane_sidebar.px(2, self.scale); // design system: fill inset xs
        const f: pane_sidebar.Rect = .{ .left = l.toggle.left + inset, .top = l.toggle.top + inset, .right = l.toggle.right - inset, .bottom = l.toggle.bottom - inset };
        fillRound(hdc, f, pane_sidebar.px(4, self.scale), rgb(shade(t.surface, icon_button.fillDelta(state, t.dark))));
    }
    const ink = if (enabled) t.text else rgb(color_math.mix(t.surface, unrgb(t.text), 1.0 - disabled_toward_bg));
    glyph(hdc, self.scale, l.toggle, if (self.mode == .expanded) glyph_close_pane else glyph_open_pane, 12, ink);
}

/// The expanded list (T2290, Mac 0a547522d): the rail's own raised card at
/// the panel's width - no flat panel down the window's side any more.
fn paintExpanded(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    self.paintCard(hdc, l, t);
    self.paintRows(hdc, l, t);
}

/// The sidebar's card, in either mode, and the column round it (T2290; Mac
/// 351868cb5 `PaneSidebarCard`). Elevated, it is an UNFOCUSED PANE's card -
/// the pane corner radius, hairline rim, sheet (glass or solid) and shadow
/// over the desk - so it reads as one more card beside the panes. Flat, whose
/// panes have no card, it keeps the side panel's (the banner's material).
fn paintCard(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const desk = self.window.deskBackdrop();
    const material: Material = if (desk != null) .{ .pane = self.window.paneGlass() } else .card;
    ensureMaterial(&self.card, hdc, l.width, l.height, t.bg, self.scale, material, desk, l.card);
    if (self.card.dc) |mem| {
        _ = w32.BitBlt(hdc, 0, 0, l.width, l.height, mem, 0, 0, w32.SRCCOPY);
    } else {
        fillRect(hdc, .{ .right = l.width, .bottom = l.height }, rgb(t.bg));
        fillRound(hdc, l.card, pane_sidebar.px(8, self.scale), rgb(t.surface));
    }
}

/// The card `paintCard` draws, in the window's client pixels, for the
/// window's desk paint to cast its shadow (T1894): the card is flush with the
/// column's trailing edge, and this child cannot paint past its own rect, so
/// the shadow Mac spills onto the grid margin has to come from the window.
/// Null when the column is not on screen, in the flat style, or mid-glide -
/// the gliding column is an overlay, and the card under it settles when the
/// glide does.
pub fn deskCard(self: *PaneSidebar) ?w32.RECT {
    if (!self.elevated() or self.column != null) return null;
    if (w32.IsWindowVisible(self.hwnd) == 0) return null;
    const parent = self.window.hwnd orelse return null;
    const l = self.currentLayout();
    if (l.card.right <= l.card.left or l.card.bottom <= l.card.top) return null;
    var wr: w32.RECT = undefined;
    if (w32.GetWindowRect(self.hwnd, &wr) == 0) return null;
    var origin: w32.POINT = .{ .x = wr.left, .y = wr.top };
    if (w32.ScreenToClient(parent, &origin) == 0) return null;
    return .{
        .left = origin.x + l.card.left,
        .top = origin.y + l.card.top,
        .right = origin.x + l.card.right,
        .bottom = origin.y + l.card.bottom,
    };
}

/// The header (toggle + caption + buttons), the section rule and caption,
/// and the rows of the expanded panel.
fn paintRows(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    if (self.paint_bare) return;
    // Header: the toggle first, "PANES" (or "ALL WINDOWS") after it, the
    // all-windows button at the trailing edge.
    if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
    const caption = if (self.all_windows)
        std.unicode.utf8ToUtf16LeStringLiteral("ALL WINDOWS")
    else
        std.unicode.utf8ToUtf16LeStringLiteral("PANES");
    const caption_right = (if (l.add.width() > 0) l.add.left else l.scope.left) - pane_sidebar.px(pane_sidebar.sm_dip, self.scale);
    drawText(hdc, caption, .{
        .left = l.caption_x,
        .top = l.header.top,
        .right = caption_right,
        .bottom = l.header.bottom,
    }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    // ALL WINDOWS carries how many windows, styled as a project header's
    // count (T1924; Mac `PaneSidebarCount` beside the caption, 6pt after it).
    if (self.all_windows) {
        var nb: [16]u8 = undefined;
        const count8 = std.fmt.bufPrint(&nb, "{d}", .{self.window_count}) catch "";
        var cw: [16]u16 = undefined;
        const cn = std.unicode.utf8ToUtf16Le(&cw, count8) catch 0;
        const left = l.caption_x + textWidth(hdc, caption) + pane_sidebar.px(6, self.scale);
        if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        if (left + textWidth(hdc, cw[0..cn]) <= caption_right) {
            drawText(hdc, cw[0..cn], .{ .left = left, .top = l.header.top, .right = caption_right, .bottom = l.header.bottom }, t.secondary, w32.DT_VCENTER);
        }
    }
    self.paintToggle(hdc, l, t);
    self.paintScope(hdc, l, t);
    self.paintAdd(hdc, l, t);
    self.paintSearch(hdc, l, t);
    // Below the controls, everything scrolls (T1878): clipped to the
    // viewport, so a row passing under the header is cut there.
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    const vp = l.viewport;
    if (vp.height() > 0) _ = w32.IntersectClipRect(hdc, vp.left, vp.top, vp.right, vp.bottom);
    if (l.no_match) |r| {
        // Mac's tertiary note: information, not an error.
        if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        drawText(hdc, std.unicode.utf8ToUtf16LeStringLiteral("No matching panes"), r, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    }

    if (l.section_rule) |r| fillRect(hdc, r, ruleColor(t));
    if (l.stashed_caption) |cap| {
        var buf: [32]u8 = undefined;
        // Only a tray that holds something is captioned (T2313, Mac
        // 82b9c5501), so the caption always carries the count.
        const stashed = self.entries.items.len - l.first_stashed;
        const text8 = std.fmt.bufPrint(&buf, "STASHED \u{00B7} {d}", .{stashed}) catch "STASHED";
        var wbuf: [32]u16 = undefined;
        const wn = std.unicode.utf8ToUtf16Le(&wbuf, text8) catch 0;
        if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        // In by its rows' level under this window's header (T2324).
        const indent = if (l.first_stashed < l.count) l.indent[l.first_stashed] else 0;
        drawText(hdc, wbuf[0..wn], .{ .left = l.caption_x + indent, .top = cap.top, .right = cap.right, .bottom = cap.bottom }, t.secondary, w32.DT_VCENTER);
    }
    // The outline's hairlines and heads - or, in the single roster, this
    // window's header (T2324).
    self.paintOutline(hdc, l, t);

    const emphasized = self.isEmphasized();
    const clip = clipOf(hdc);
    for (0..l.count) |i| {
        if (!l.shown(i) or self.paint_lifted == i or self.lifted_items.isSet(i)) continue;
        const hovered = self.rowHovered(i);
        if (clip) |c| if (!motion.overlaps(c, l.items[i])) {
            const e = self.entries.items[i];
            self.tallyUnpainted(e, l.items[i], !hovered and e.bell and e.section == .stashed);
            continue;
        };
        self.paintRow(hdc, l, i, l.items[i], hovered, emphasized, t);
    }
    self.paintDropSlot(hdc, l, t);
    self.paintSticky(hdc, l, t);
    self.paintThumb(hdc, l, t);
}

/// One expanded row at `r` - where the layout put it, slid (T2304), or held
/// by the pointer.
fn paintRow(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, i: usize, r: pane_sidebar.Rect, hovered: bool, emphasized: bool, t: Theme) void {
    const e = self.entries.items[i];
    // The pill, its sheen and its glyph: what a rail tile is too.
    const pill = self.paintPill(hdc, r, e, l.indent[i], hovered, emphasized, false, t);
    const icon_r = pill.icon;
    const ink = if (e.selected) t.text else t.secondary;
    const text_inset = pane_sidebar.px(toc.text_inset_dip, self.scale);

    // The trailing edge: the hover buttons (T2280, Mac dc2bbab6b -
    // stash/restore on this window's rows, then the x on every row,
    // T2298) replace the bell
    // dot while the pointer is on the row, so the two never crowd each
    // other. A question has no accessory any more (Mac 2924ea5cc).
    const text_left = icon_r.right + pane_sidebar.px(pane_sidebar.icon_text_gap_dip, self.scale);
    var text_right = r.right - text_inset;
    const sm = pane_sidebar.px(pane_sidebar.sm_dip, self.scale);
    // Renamed in place (T2339): the field takes the buttons' room too, and
    // they stay away while it edits (Mac `isHovered && !isEditing`).
    const editing = self.renamingPane(e.pane);
    if (hovered and !editing) {
        // Another window's row offers the x alone (T2298); a terminal's
        // leads with the pencil (T2339).
        const x = l.rowClose(i, self.scale);
        text_right = x.left - sm;
        if (row_menu.rowOffersStash(e.own)) {
            const button = l.rowButton(i, self.scale);
            text_right = button.left - sm;
            self.paintRowButton(hdc, .{ .item_button = i }, button, if (e.section == .stashed) glyph_restore else glyph_stash, pill.under, t);
        }
        const pencil = l.rowRename(i, self.scale);
        if (pencil.width() > 0) {
            text_right = pencil.left - sm;
            self.paintRowButton(hdc, .{ .item_rename = i }, pencil, glyph_rename, pill.under, t);
        }
        self.paintRowButton(hdc, .{ .item_close = i }, x, glyph_close, pill.under, t);
    } else if (e.bell and e.section == .stashed and !editing) {
        // Mac's accessory: a stashed pane's bell dot.
        const d = @max(pane_sidebar.px(7, self.scale), 3);
        self.paintBellDot(hdc, text_right - @divTrunc(d, 2), icon_r.centerY(), t);
        text_right -= d + sm;
    }

    // The title, and the subtitle under it, centred as one block on the
    // pill beside the glyph (Mac's row is one height whatever it holds).
    const block = self.metrics.title_h + if (e.subtitle.len > 0) self.metrics.caption_h else 0;
    const text_top = r.top + @divTrunc(r.height() - block, 2);
    const title_bottom = text_top + self.metrics.title_h;
    if (self.title_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
    const title_r: pane_sidebar.Rect = .{ .left = text_left, .top = text_top, .right = text_right, .bottom = title_bottom };
    if (editing) {
        self.paintRenameField(hdc, title_r, self.title_font, pill.under, t);
    } else drawText(hdc, e.title, title_r, ink, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    if (e.subtitle.len > 0) {
        if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        drawText(hdc, e.subtitle, .{
            .left = text_left,
            .top = title_bottom,
            .right = text_right,
            .bottom = title_bottom + self.metrics.caption_h,
        }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    }
}

/// The stuck project header (T1878, Mac's sticky section header): painted
/// last, on the panel's own material across the viewport's width, so the
/// rows passing beneath it never show through its text.
fn paintSticky(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const k = l.sticky orelse return;
    const hd = l.heads[k];
    if (hd.index >= self.groups.items.len) return;
    const band: pane_sidebar.Rect = .{ .left = l.viewport.left, .top = hd.rect.top, .right = l.viewport.right, .bottom = hd.rect.bottom };
    // The card's own material under it (T2290: one card in both styles).
    if (self.card.dc) |m| {
        _ = w32.BitBlt(hdc, band.left, band.top, band.width(), band.height(), m, band.left, band.top, w32.SRCCOPY);
    } else fillRect(hdc, band, rgb(t.surface));
    self.paintHead(hdc, hd, k, self.groups.items[hd.index], t);
}

/// The overlay thumb on the scrolled region's trailing edge, while there is
/// anything to scroll: the app's overlay scrollbar idiom (the Activity
/// Monitor's), brighter while it is being dragged.
fn paintThumb(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const r = scroll_mod.thumb(l, self.scale) orelse return;
    const dragging = self.thumb_drag != null;
    const ink = if (dragging) shade(t.surface, if (t.dark) 96 else -96) else shade(t.surface, if (t.dark) 56 else -56);
    fillRound(hdc, r, @divTrunc(r.width(), 2), rgb(ink));
}

/// The search field's text box: right of the magnifier, left of the clear
/// button (or the field's own `sm` inset while there is nothing to clear).
fn searchTextBox(self: *const PaneSidebar, l: *const pane_sidebar.Layout) pane_sidebar.Rect {
    const sm = pane_sidebar.px(pane_sidebar.sm_dip, self.scale);
    const r = l.search;
    const left = r.left + sm + pane_sidebar.px(pane_sidebar.row_button_dip, self.scale) + sm;
    const right = if (l.search_text) l.search_clear.left - sm else r.right - sm;
    return .{ .left = left, .top = r.top, .right = @max(right, left), .bottom = r.bottom };
}

/// How far the query is scrolled left so the caret stays in view, measured
/// with `hdc`'s current font.
fn searchScroll(self: *const PaneSidebar, hdc: w32.HDC, box: pane_sidebar.Rect) i32 {
    const caret_x = textWidth(hdc, self.search.text()[0..self.search.caret]);
    return search_field.scrollFor(caret_x, box.width() - 1);
}

/// The all-windows search field (T1877): Mac's soft capsule in the design
/// system's input shape - a 4 DIP rounded well a step off the surface, the
/// viewer find card's field - with the magnifier leading, the "Search"
/// placeholder or the query, and the clear button once there is one. While
/// the column holds the keyboard the caret shows and the well carries the
/// accent underline a Windows text box shows when it is focused.
fn paintSearch(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const r = l.search;
    if (r.width() <= 0) return;
    const s = self.scale;
    const sm = pane_sidebar.px(pane_sidebar.sm_dip, s);
    const radius = pane_sidebar.px(4, s);
    const well = shade(t.surface, if (t.dark) -14 else 14);
    fillRound(hdc, r, radius, rgb(well));
    if (self.search_focus) {
        const line = @max(pane_sidebar.px(2, s), 1);
        fillRect(hdc, .{ .left = r.left + radius, .top = r.bottom - line, .right = r.right - radius, .bottom = r.bottom }, rgb(t.accent));
    }

    const box = pane_sidebar.px(pane_sidebar.row_button_dip, s);
    const gtop = r.top + @divTrunc(r.height() - box, 2);
    // The magnifier labels the field; it is not a button.
    glyph(hdc, s, .{ .left = r.left + sm, .top = gtop, .right = r.left + sm + box, .bottom = gtop + box }, glyph_search, 11, t.secondary);

    const tb = self.searchTextBox(l);
    if (self.title_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
    const text = self.search.text();
    var off: i32 = 0;
    if (text.len == 0) {
        drawText(hdc, std.unicode.utf8ToUtf16LeStringLiteral("Search"), tb, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    } else {
        off = self.searchScroll(hdc, tb);
        const saved = w32.SaveDC(hdc);
        _ = w32.IntersectClipRect(hdc, tb.left, tb.top, tb.right, tb.bottom);
        drawText(hdc, text, .{ .left = tb.left - off, .top = tb.top, .right = tb.left - off + 100000, .bottom = tb.bottom }, t.text, w32.DT_VCENTER);
        _ = w32.RestoreDC(hdc, saved);
    }
    if (self.search_focus) {
        const cx = tb.left + textWidth(hdc, text[0..self.search.caret]) - off;
        const ch = self.metrics.title_h;
        const ctop = r.top + @divTrunc(r.height() - ch, 2);
        fillRect(hdc, .{ .left = cx, .top = ctop, .right = cx + @max(pane_sidebar.px(1, s), 1), .bottom = ctop + ch }, t.text);
    }

    if (l.search_text) {
        const b = l.search_clear;
        const state: icon_button.State = if (self.hoverIs(.search_clear))
            (if (std.meta.eql(self.pressed, pane_sidebar.Hit.search_clear)) .pressed else .hover)
        else
            .normal;
        if (icon_button.paintsFill(state)) {
            fillRound(hdc, b, radius, rgb(shade(well, icon_button.fillDelta(state, t.dark))));
        }
        glyph(hdc, s, b, glyph_close, 10, t.secondary);
    }
}

/// The caret index a click at `x` (in the column's client coordinates) lands
/// on: the boundary nearest the point, measured the way `paintSearch` lays
/// the text out.
fn searchCaretAt(self: *PaneSidebar, x: i32) usize {
    const l = self.currentLayout();
    const tb = self.searchTextBox(&l);
    const dc = w32.CreateCompatibleDC(null) orelse return self.search.len;
    defer _ = w32.DeleteDC(dc);
    if (self.title_font) |f| _ = w32.SelectObject(dc, @ptrCast(f));
    const off = self.searchScroll(dc, tb);
    const text = self.search.text();
    const target = x - tb.left + off;
    var prev: i32 = 0;
    for (1..text.len + 1) |i| {
        const wdt = textWidth(dc, text[0..i]);
        if (wdt >= target) return if (target - prev < wdt - target) i - 1 else i;
        prev = wdt;
    }
    return text.len;
}

/// The all-windows toggle (Mac's `macwindow.on.rectangle` header button).
/// Mac reads on/off from a filled glyph; the icon font has no filled twin,
/// so on is the Windows toggle-button vocabulary instead: the button stays
/// filled, as a checked toolbar toggle does.
fn paintScope(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    if (l.scope.width() <= 0) return;
    const state: icon_button.State = if (self.hoverIs(.scope))
        (if (std.meta.eql(self.pressed, pane_sidebar.Hit.scope)) .pressed else .hover)
    else
        .normal;
    const inset = pane_sidebar.px(2, self.scale); // design system: fill inset xs
    const f: pane_sidebar.Rect = .{ .left = l.scope.left + inset, .top = l.scope.top + inset, .right = l.scope.right - inset, .bottom = l.scope.bottom - inset };
    if (self.all_windows) {
        const checked: icon_button.State = if (state == .normal) .hover else .pressed;
        fillRound(hdc, f, pane_sidebar.px(4, self.scale), rgb(shade(t.surface, icon_button.fillDelta(checked, t.dark) * 2)));
    } else if (icon_button.paintsFill(state)) {
        fillRound(hdc, f, pane_sidebar.px(4, self.scale), rgb(shade(t.surface, icon_button.fillDelta(state, t.dark))));
    }
    glyph(hdc, self.scale, l.scope, glyph_windows, 12, t.text);
}

/// The header's new-window + (T2323, Mac's `.plus` header button): a plain
/// icon button beside the all-windows toggle, never checked.
fn paintAdd(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    if (l.add.width() <= 0) return;
    const state: icon_button.State = if (self.hoverIs(.add))
        (if (std.meta.eql(self.pressed, pane_sidebar.Hit.add)) .pressed else .hover)
    else
        .normal;
    const inset = pane_sidebar.px(2, self.scale); // design system: fill inset xs
    const f: pane_sidebar.Rect = .{ .left = l.add.left + inset, .top = l.add.top + inset, .right = l.add.right - inset, .bottom = l.add.bottom - inset };
    if (icon_button.paintsFill(state)) {
        fillRound(hdc, f, pane_sidebar.px(4, self.scale), rgb(shade(t.surface, icon_button.fillDelta(state, t.dark))));
    }
    glyph(hdc, self.scale, l.add, glyph_add, 12, t.text);
}

/// The outline's own furniture (T1829): the hairlines between windows and
/// the project and window headers - no divider or caption before a window's
/// stash (T2313, Mac 47b39b1cb). Rows are painted by the caller, as in the
/// single roster.
fn paintOutline(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const rule_color = ruleColor(t);
    for (l.rules[0..l.rule_count]) |r| fillRect(hdc, r, rule_color);
    for (l.heads[0..l.head_count], 0..) |hd, k| {
        if (hd.index >= self.groups.items.len) continue;
        // The pinned header is painted over the rows, by `paintSticky`; a
        // held one over everything, by `paintHeldItem` (T2337).
        if (l.sticky == k or self.lifted_heads.isSet(k)) continue;
        self.paintHead(hdc, hd, k, self.groups.items[hd.index], t);
        self.paintJoinOutline(hdc, hd, t);
    }
}

/// A project header while a window is dragged into its group (T2338, Mac
/// `PaneSidebarJoinHighlight`): outlined in the accent color, so a drop just
/// past its last window reads as joining it rather than landing after it.
fn paintJoinOutline(self: *PaneSidebar, hdc: w32.HDC, hd: pane_sidebar.Head, t: Theme) void {
    if (hd.kind != .project) return;
    const d = if (self.item_drag) |*x| x else return;
    if (!d.cross) return;
    const row = itemSibling(d, &self.groups.items[hd.index], .project) orelse return;
    const a = joinAlpha(d, row, self.paint_ms);
    if (a <= 0) return;
    const width = @max(1, pane_sidebar.px(2, self.scale));
    const radius = pane_sidebar.px(toc.row_corner_dip, self.scale);
    strokeRound(hdc, hd.rect, radius, rgb(color_math.mix(t.surface, t.accent, a)), width);
    if (!self.join_logged) {
        self.join_logged = true;
        log.info("pane sidebar join outline drawn project={s}", .{d.rowProject(row) orelse ""});
    }
}

/// A window header (Mac `PaneSidebarWindowHeader`) or a project header
/// (`PaneSidebarProjectHeader`): chevron, name, and at the trailing edge the
/// window's pane count or the project's window count (a window's question
/// badge went with T2280, Mac 2924ea5cc). Another window's header lights on
/// hover, since a click raises it. This window's, folded, carries the
/// selection a row would (T2340, Mac c4dbe30be): its selected pane is inside
/// the fold.
fn paintHead(self: *PaneSidebar, hdc: w32.HDC, hd: pane_sidebar.Head, k: usize, g: Group, t: Theme) void {
    const sm = pane_sidebar.px(pane_sidebar.sm_dip, self.scale);
    const text_inset = pane_sidebar.px(toc.text_inset_dip, self.scale);
    const hovered = self.hoverIs(.{ .head = k }) or self.hoverIs(.{ .head_fold = k }) or self.hoverIs(.{ .head_close = k }) or
        self.hoverIs(.{ .head_add = k }) or self.hoverIs(.{ .head_rename = k });
    const project = hd.kind == .project;
    // Renamed in place (T2339): the count stays, the buttons stay away.
    const editing = self.renamingHead(hd, g);
    var under = t.surface;
    const folded = if (project) self.folded_projects.contains(g.project_key) else self.groupFolded(g.key, self.filterActive());
    const selected = self.headDrawnSelected(hd, g);
    const emphasized = selected and self.isEmphasized();
    if (selected or (hovered and (project or !g.own))) {
        const sel = list_selection.rowPaint(t.surface, t.accent, .{ .selected = selected, .focused = emphasized, .hovered = hovered and !selected, .focus_visible = false });
        if (sel.fill) |f| {
            fillRound(hdc, hd.rect, pane_sidebar.px(toc.row_corner_dip, self.scale), rgb(f));
            under = f;
        }
        if (sel.indicator) |c| {
            const r = hd.rect;
            const bar = toc.selectionIndicator(r.height(), self.scale);
            fillRound(hdc, .{ .left = r.left + bar.left, .top = r.top + bar.top, .right = r.left + bar.left + bar.width, .bottom = r.top + bar.top + bar.height }, bar.radius, rgb(c));
        }
    }
    glyph(hdc, self.scale, hd.chevron, if (folded) glyph_chevron_right else glyph_chevron_down, 8, t.secondary);
    // A window's icon, in its panes' icon column (T2340, Mac 28f6cde09).
    if (hd.icon.width() > 0) glyph(hdc, self.scale, hd.icon, glyph_app_window, 12, t.secondary);

    // The trailing count first, so the name knows its room. Hovered, the
    // pencil, + and x take the count's place (T2298, T2323, T2339; Mac
    // 345be6b02, 44aa923f0, a13bf6f43); the name stops short of the x either
    // way, so nothing shifts when they appear, and gives way to the pencil
    // and the + only while they are up.
    const x = pane_sidebar.headCloseRect(hd, self.scale);
    const plus = pane_sidebar.headAddRect(hd, self.scale);
    const pencil = pane_sidebar.headRenameRect(hd, self.scale);
    const buttons = hovered and !editing;
    var right = hd.rect.right - text_inset;
    const text_r: pane_sidebar.Rect = .{ .left = hd.label_x, .top = hd.chevron.top - pane_sidebar.px(6, self.scale), .right = right, .bottom = hd.chevron.bottom + pane_sidebar.px(6, self.scale) };
    {
        var nb: [16]u8 = undefined;
        const count8 = std.fmt.bufPrint(&nb, "{d}", .{if (project) g.project_size else g.panes}) catch "";
        var cw: [16]u16 = undefined;
        const cn = std.unicode.utf8ToUtf16Le(&cw, count8) catch 0;
        if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        const w = textWidth(hdc, cw[0..cn]);
        if (buttons) {
            self.paintRowButton(hdc, .{ .head_rename = k }, pencil, glyph_rename, under, t);
            self.paintRowButton(hdc, .{ .head_add = k }, plus, glyph_add, under, t);
            self.paintRowButton(hdc, .{ .head_close = k }, x, glyph_close, under, t);
        } else drawText(hdc, cw[0..cn], .{ .left = right - w, .top = text_r.top, .right = right, .bottom = text_r.bottom }, t.secondary, w32.DT_VCENTER | w32.DT_RIGHT);
        right = @min(right - w, if (buttons) pencil.left else x.left) - sm;
    }

    // The field holds the name in its own weight: the project as typed in
    // the titles (the header shows it upper-cased), a window's whole title.
    if (editing) {
        const font = if (project) self.caption_bold_font else self.title_bold_font;
        if (font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        const line_h = if (project) self.metrics.caption_h else self.metrics.title_h;
        const top = hd.chevron.centerY() - @divTrunc(line_h, 2);
        self.paintRenameField(hdc, .{ .left = hd.label_x, .top = top, .right = right, .bottom = top + line_h }, font, under, t);
        return;
    }
    if (project) {
        if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        drawText(hdc, g.project, .{ .left = hd.label_x, .top = text_r.top, .right = right, .bottom = text_r.bottom }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
        return;
    }
    // The PARENT row: the window's name at a group's weight, then - on
    // this window's, among other windows - a quiet "This Window" (a tab of a
    // tabbed window says "This Tab": its window's other tabs are listed
    // beside it). Heading the single roster it says nothing (T2324, Mac
    // e94a9737e `showsThisWindowTag`): only among others does it need saying.
    if (self.title_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
    const tag = if (g.tabbed) std.unicode.utf8ToUtf16LeStringLiteral("This Tab") else std.unicode.utf8ToUtf16LeStringLiteral("This Window");
    const tagged = pane_sidebar.showsThisWindowTag(g.own, self.all_windows);
    var name_right = right;
    var tag_w: i32 = 0;
    if (tagged) {
        if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        tag_w = textWidth(hdc, tag);
        if (self.title_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        const gap = pane_sidebar.px(5, self.scale);
        const name_w = textWidth(hdc, g.label);
        // The name takes what it needs; the tag gives way first.
        name_right = @min(right, hd.label_x + name_w);
        if (name_right + gap + tag_w > right) name_right = @max(hd.label_x, right - gap - tag_w);
    }
    drawText(hdc, g.label, .{ .left = hd.label_x, .top = text_r.top, .right = name_right, .bottom = text_r.bottom }, t.text, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    if (tagged) {
        if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        const left = name_right + pane_sidebar.px(5, self.scale);
        drawText(hdc, tag, .{ .left = left, .top = text_r.top, .right = right, .bottom = text_r.bottom }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    }
}

fn textWidth(hdc: w32.HDC, text: []const u16) i32 {
    if (text.len == 0) return 0;
    var r = w32.RECT{ .left = 0, .top = 0, .right = 100000, .bottom = 0 };
    _ = w32.DrawTextW(hdc, text.ptr, @intCast(text.len), &r, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
    return r.right - r.left;
}

/// The empty tray's well (T1844, T2276; Mac 543489bca
/// `PaneSidebarEmptyStashSlot`): a dashed outline with the stash glyph - and,
/// as a row, what it is for. Faint at rest ("Drag a pane here to stash it"),
/// brighter during a drag ("Drop to stash - it keeps running"). Lit when a
/// drag would land in it by the drop highlight, which washes the slot
/// (`drop_highlight` `.stash_slot`). Mac's tertiary ink is the secondary here:
/// the design system's contrast floor has no fainter text, so the outline
/// carries the rest/drag difference.
fn paintDropSlot(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const r = l.drop_slot orelse return;
    const radius = pane_sidebar.px(toc.row_corner_dip, self.scale);
    strokeDashed(hdc, r, radius, self.scale, rgb(color_math.mix(t.surface, t.ink, if (self.drag_active) 0.30 else 0.14)));
    if (l.mode != .expanded) {
        glyph(hdc, self.scale, r, glyph_stash, 12, t.secondary);
        return;
    }
    const text_inset = pane_sidebar.px(toc.text_inset_dip, self.scale);
    const icon_box = pane_sidebar.px(16, self.scale);
    const icon_r: pane_sidebar.Rect = .{ .left = r.left + text_inset, .top = r.top, .right = r.left + text_inset + icon_box, .bottom = r.bottom };
    glyph(hdc, self.scale, icon_r, glyph_stash, 12, t.secondary);
    if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
    const label = if (self.drag_active)
        std.unicode.utf8ToUtf16LeStringLiteral("Drop to stash \u{2014} it keeps running")
    else
        std.unicode.utf8ToUtf16LeStringLiteral("Drag a pane here to stash it");
    drawText(hdc, label, .{
        .left = icon_r.right + pane_sidebar.px(8, self.scale),
        .top = r.top,
        .right = r.right - text_inset,
        .bottom = r.bottom,
    }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
}

/// A 1 px dashed rounded outline on `r`: Mac's 4-on, 3-off dash, scaled to
/// the DPI, with nothing filled.
fn strokeDashed(hdc: w32.HDC, r: pane_sidebar.Rect, radius: i32, scale: f32, color: u32) void {
    const dash = [2]u32{ @intCast(@max(pane_sidebar.px(4, scale), 1)), @intCast(@max(pane_sidebar.px(3, scale), 1)) };
    const brush: w32.LOGBRUSH = .{ .lbStyle = w32.BS_SOLID, .lbColor = color, .lbHatch = 0 };
    const pen = w32.ExtCreatePen(w32.PS_COSMETIC | w32.PS_USERSTYLE, 1, &brush, dash.len, &dash) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, old_pen);
    const old_brush = w32.SelectObject(hdc, w32.GetStockObject(w32.NULL_BRUSH));
    defer _ = w32.SelectObject(hdc, old_brush);
    _ = w32.RoundRect(hdc, r.left, r.top, r.right, r.bottom, 2 * radius, 2 * radius);
}

/// One of a hovered row's compact buttons (stash / restore, or the x, T2280):
/// the glyph, on the icon-button hover fill while the pointer is on it. The x
/// is an ordinary button, not trash mode's red disc - it closes undoably.
/// Every item button - a row's stash/restore and x, a header's x - in one
/// style (T2298, Mac 345be6b02 `PaneSidebarItemButton`): a circle of the
/// ink washed over what it sits on, deeper under the pointer (8% -> 18%),
/// and a glyph that brightens from secondary to primary, so it reads as
/// clickable before it is hovered. Mac's on-accent variant has no Windows
/// counterpart: the selected row here is a neutral fill, never an accent
/// pill (T828).
fn paintRowButton(self: *PaneSidebar, hdc: w32.HDC, hit: pane_sidebar.Hit, b: pane_sidebar.Rect, g: u16, under: color_math.Rgb, t: Theme) void {
    const hot = self.hoverIs(hit);
    const pressed = hot and std.meta.eql(self.pressed, hit);
    const wash: f64 = if (pressed) item_button_wash_pressed else if (hot) item_button_wash_hover else item_button_wash_rest;
    fillRound(hdc, b, @divTrunc(b.width(), 2), rgb(color_math.mix(under, t.ink, wash)));
    glyph(hdc, self.scale, b, g, 10, if (hot) t.text else t.secondary);
}

/// The item button's wash (Mac `PaneSidebarItemButton.wash`), and a deeper
/// one while it is held.
const item_button_wash_rest: f64 = 0.08;
const item_button_wash_hover: f64 = 0.18;
const item_button_wash_pressed: f64 = 0.26;

/// The pointer is on row `i` or one of its buttons.
fn rowHovered(self: *const PaneSidebar, i: usize) bool {
    return self.hoverIs(.{ .item = i }) or self.hoverIs(.{ .item_button = i }) or self.hoverIs(.{ .item_close = i }) or
        self.hoverIs(.{ .item_rename = i });
}

fn paintMini(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    // The column is the terminal background - the desk, in the elevated
    // style (T1850) - and the rail is the raised card on it.
    self.paintCard(hdc, l, t);

    self.paintToggle(hdc, l, t);
    // The tiles scroll under the toggle (T1878), clipped to the card's inset.
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    const vp = l.viewport;
    if (vp.height() > 0) _ = w32.IntersectClipRect(hdc, vp.left, vp.top, vp.right, vp.bottom);
    if (l.section_rule) |r| fillRect(hdc, r, ruleColor(t));
    for (l.rules[0..l.rule_count]) |r| fillRect(hdc, r, ruleColor(t));
    // This window's header with its text taken away (T2324): its + alone,
    // always shown, on the card's material.
    if (l.rail_add.width() > 0 and !self.paint_bare) self.paintRowButton(hdc, .rail_add, l.rail_add, glyph_add, t.surface, t);

    const emphasized = self.isEmphasized();
    const clip = clipOf(hdc);
    for (0..l.count) |i| {
        if (self.paint_lifted == i) continue;
        if (clip) |c| if (!motion.overlaps(c, l.items[i])) {
            const e = self.entries.items[i];
            self.tallyUnpainted(e, l.items[i], e.bell and e.section == .stashed);
            continue;
        };
        self.paintTile(hdc, i, l.items[i], self.rowHovered(i), emphasized, t);
    }
    self.paintDropSlot(hdc, l, t);
    self.paintThumb(hdc, l, t);
}

/// One rail tile at `r` (see `paintRow`).
fn paintTile(self: *PaneSidebar, hdc: w32.HDC, i: usize, r: pane_sidebar.Rect, hovered: bool, emphasized: bool, t: Theme) void {
    const e = self.entries.items[i];
    // The row without its text (T2279): the same pill, sheen and glyph, and
    // the glassy rim a bare glyph needs to read as a button (T2309).
    _ = self.paintPill(hdc, r, e, 0, hovered, emphasized, true, t);
    // The corner (Mac `tile`): a stashed pane's bell dot, at the pill's
    // top trailing corner. The question disc that sat there went with
    // T2280 (Mac 2924ea5cc).
    if (e.bell and e.section == .stashed) {
        const d = @max(pane_sidebar.px(7, self.scale), 3);
        const one = pane_sidebar.px(1, self.scale);
        const three = pane_sidebar.px(3, self.scale);
        self.paintBellDot(hdc, r.right + one - @divTrunc(d, 2), r.top + three + @divTrunc(d, 2), t);
    }
}

/// What a cache holds (T2290): the side panel's card on the flat terminal
/// background, or - elevated - an unfocused pane's card over the desk, its
/// sheet glass when the panes are.
const Material = union(enum) {
    card,
    pane: bool,
};

/// Build `cache` when anything it was built from changed. With a `desk`
/// (the elevated style, T1850) the card is composited over the window's
/// gradient - this window sits at the desk's left edge, so its pixels are the
/// desk's first `w` columns - at the layout's own `card` rect; without one it
/// is the side panel's card on the flat terminal background.
fn ensureMaterial(
    cache: *CardCache,
    hdc: w32.HDC,
    w: i32,
    h: i32,
    bg: color_math.Rgb,
    scale: f32,
    material: Material,
    desk: ?PaneDesk.Backdrop,
    card: pane_sidebar.Rect,
) void {
    const gen: u32 = if (desk) |d| d.gen else 0;
    const ins: [4]i32 = .{ card.left, card.top, card.right, card.bottom };
    const stale = cache.dc == null or cache.w != w or cache.h != h or
        !std.meta.eql(cache.bg, bg) or cache.scale != scale or
        cache.desk_gen != gen or !std.meta.eql(cache.insets, ins) or !std.meta.eql(cache.material, material);
    if (!stale) return;
    cache.release();
    if (w <= 0 or h <= 0) return;

    var bmi = std.mem.zeroes(w32.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;

    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    var bits: ?*anyopaque = null;
    const bmp = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
        _ = w32.DeleteDC(mem_dc);
        return;
    };
    const raw = bits orelse {
        _ = w32.DeleteObject(bmp);
        _ = w32.DeleteDC(mem_dc);
        return;
    };
    _ = w32.SelectObject(mem_dc, bmp);
    const pixels = @as([*]u32, @ptrCast(@alignCast(raw)))[0..@intCast(w * h)];
    if (desk) |d| {
        copyDesk(pixels, w, h, d, bg);
        // The pane card exactly on `layout().card`, drawn by the painter the
        // panes' own cards are: no glow (it is never the focused card), the
        // resting rim, and the sheet a pane wears.
        const cards = [1]pane_elevation.Card{.{ .left = card.left, .top = card.top, .right = card.right, .bottom = card.bottom }};
        pane_elevation.paintCards(pixels, @intCast(w), @intCast(h), &cards, .{
            .fill = bg,
            .is_light = color_math.isLight(bg),
            .scale = scale,
            .glass = switch (material) {
                .pane => |glass| glass,
                .card => false,
            },
        });
    } else {
        // The banner card's margin IS the rail margin (12 DIP), so the card
        // the material draws lands exactly on `layout().card`.
        banner_card.render(pixels, banner_card.Metrics.init(w, h, scale), bg);
    }

    cache.* = .{ .dc = mem_dc, .bmp = bmp, .w = w, .h = h, .bg = bg, .scale = scale, .desk_gen = gen, .insets = ins, .material = material };
}

/// The desk's first `w` x `h` pixels into `out` - the sidebar's column starts
/// at the desk's left edge. Past the desk (a size change mid-flight) is the
/// terminal background.
fn copyDesk(out: []u32, w: i32, h: i32, d: PaneDesk.Backdrop, bg: color_math.Rgb) void {
    const fill: u32 = (@as(u32, bg.r) << 16) | (@as(u32, bg.g) << 8) | bg.b;
    const uw: usize = @intCast(w);
    const dw: usize = @intCast(d.w);
    for (0..@intCast(h)) |y| {
        const row = out[y * uw ..][0..uw];
        if (y >= @as(usize, @intCast(d.h))) {
            @memset(row, fill);
            continue;
        }
        const n = @min(uw, dw);
        @memcpy(row[0..n], d.pixels[y * dw ..][0..n]);
        if (n < uw) @memset(row[n..], fill);
    }
}

/// Double-buffered: the whole column is drawn into a memory DC and blitted
/// once, so a refresh never shows a half-painted list.
/// The frame into `hdc`, buffered - only the part `update` asks for (T1925):
/// a motion frame invalidates its moving pills alone, so the buffer is their
/// box and the column's other rows are tallied rather than drawn. The frame
/// is laid out and painted in the column's own coordinates either way, so
/// what lands is the same pixels a whole repaint would put there.
fn paintBuffered(self: *PaneSidebar, hdc: w32.HDC, width: i32, height: i32, update: w32.RECT) void {
    if (width <= 0 or height <= 0) return;
    const left = std.math.clamp(update.left, 0, width);
    const top = std.math.clamp(update.top, 0, height);
    const right = std.math.clamp(update.right, left, width);
    const bottom = std.math.clamp(update.bottom, top, height);
    const bw = right - left;
    const bh = bottom - top;
    if (bw <= 0 or bh <= 0) return;
    if (self.anim_armed) {
        self.motion_frames += 1;
        self.motion_px += @intCast(bw * bh);
        self.motion_client_px += @intCast(width * height);
    }
    const mem = w32.CreateCompatibleDC(hdc) orelse return self.paint(hdc, width, height);
    defer _ = w32.DeleteDC(mem);
    const bmp = w32.CreateCompatibleBitmap(hdc, bw, bh) orelse return self.paint(hdc, width, height);
    defer _ = w32.DeleteObject(bmp);
    const old = w32.SelectObject(mem, bmp);
    defer _ = w32.SelectObject(mem, old);
    _ = w32.SetViewportOrgEx(mem, -left, -top, null);
    self.paint(mem, width, height);
    _ = w32.BitBlt(hdc, left, top, bw, bh, mem, left, top, w32.SRCCOPY);
}

// -------------------------------------------------------------------------
// Input
// -------------------------------------------------------------------------

fn hitAt(self: *PaneSidebar, x: i32, y: i32) pane_sidebar.Hit {
    const l = self.currentLayout();
    return pane_sidebar.hitTest(&l, x, y, self.scale);
}

fn setHover(self: *PaneSidebar, hit: pane_sidebar.Hit) void {
    if (std.meta.eql(self.hover, hit)) return;
    self.hover = hit;
    self.syncHoverTint();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

// -------------------------------------------------------------------------
// Edge drag (T1846; Mac `PaneSidebarChrome.resizeHandle`)
// -------------------------------------------------------------------------

fn onEdgeAt(self: *PaneSidebar, x: i32, y: i32) bool {
    const l = self.currentLayout();
    return pane_sidebar.onEdgeIn(&l, x, y, self.scale, self.elevated());
}

fn screenX(hwnd: w32.HWND, x: i32, y: i32) i32 {
    var pt = w32.POINT{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &pt);
    return pt.x;
}

fn setSizeCursor() void {
    _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_SIZEWE));
}

/// The log keeps its `surface=rail` field (see `armMotion`).
fn edgeBegin(self: *PaneSidebar, hwnd: w32.HWND, x: i32, y: i32) void {
    self.pressed = .none;
    const start = pane_sidebar.edgeStartDip(self.mode, self.window.pane_sidebar_width_dip);
    self.edge = .{ .start_dip = start, .start_x = screenX(hwnd, x, y) };
    _ = w32.SetCapture(hwnd);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    setSizeCursor();
    log.info("pane sidebar edge drag start surface=rail mode={s} from={d:.0}", .{ @tagName(self.mode), start });
}

fn edgeMove(self: *PaneSidebar, hwnd: w32.HWND, x: i32, y: i32) void {
    const d = self.edge orelse return;
    setSizeCursor();
    const dx = @as(f32, @floatFromInt(screenX(hwnd, x, y) - d.start_x)) / self.scale;
    // The mode as it is NOW: a rail expanded earlier in this drag is the
    // panel from here on, and a panel tucked earlier is the rail (T2299).
    const drag = pane_sidebar.edgeDrag(self.mode, d.start_dip, dx) orelse return;
    if (drag.expanded and !self.window.paneSidebarCanExpand()) return;
    // The width first, so expanding glides the grid to it (Mac 543489bca).
    if (drag.width) |w| if (w != self.window.pane_sidebar_width_dip) self.window.setPaneSidebarWidth(w);
    if (drag.expanded != self.window.pane_sidebar_expanded) {
        log.info("pane sidebar edge drag expanded={} dx={d:.0}", .{ drag.expanded, dx });
        self.window.setPaneSidebarExpanded(drag.expanded, "edge drag");
    }
}

/// The drag ended - released, or the capture was taken away.
fn edgeEnd(self: *PaneSidebar) void {
    const d = self.edge orelse return;
    self.edge = null;
    // The bar goes out with the drag, and the edge the pointer let go over
    // is asked again from where it is (T2265; Mac 5e4f30144).
    if (!d.gutter) self.recheckEdgeHover();
    // The drag moved `remembered.width_dip` live; the file is written once,
    // when it settles (T1847).
    saveRemembered(self.window.app.core_app.alloc);
    log.info("pane sidebar edge drag end expanded={} width={d:.0}", .{ self.window.pane_sidebar_expanded, self.window.pane_sidebar_width_dip });
}

/// Ask again whether the pointer is on the edge, from where it is. No
/// readable cursor (a background desktop) reads as "off it".
fn recheckEdgeHover(self: *PaneSidebar) void {
    var pt: w32.POINT = undefined;
    const on = self.pointerOn() and w32.GetCursorPos_(&pt) != 0 and
        w32.ScreenToClient(self.hwnd, &pt) != 0 and self.onEdgeAt(pt.x, pt.y);
    self.setEdgeHover(on);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// Whether the real pointer is on the column (window regions honored).
fn pointerOn(self: *PaneSidebar) bool {
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) == 0) return false;
    return w32.WindowFromPoint(pt) == self.hwnd;
}

/// An edge drag begun in the WINDOW's gutter beside the expanded panel
/// (T2265: the elevated style's grip, Mac `pinnedEdgeGrip`). `hwnd` is the
/// window's, which takes the capture; the drag is the panel's own from there
/// on.
pub fn gutterDragBegin(self: *PaneSidebar, hwnd: w32.HWND, x: i32, y: i32) void {
    self.edgeBegin(hwnd, x, y);
    if (self.edge) |*d| d.gutter = true;
}

pub fn gutterDragMove(self: *PaneSidebar, hwnd: w32.HWND, x: i32, y: i32) void {
    self.edgeMove(hwnd, x, y);
}

pub fn gutterDragEnd(self: *PaneSidebar) void {
    self.edgeEnd();
}

pub fn gutterDragging(self: *const PaneSidebar) bool {
    return if (self.edge) |d| d.gutter else false;
}

// -------------------------------------------------------------------------
// Tooltips (Mac `.help`)
// -------------------------------------------------------------------------

fn tipEnsure(self: *PaneSidebar) ?w32.HWND {
    if (self.tip) |h| return h;
    var icc = w32.INITCOMMONCONTROLSEX{
        .dwSize = @sizeOf(w32.INITCOMMONCONTROLSEX),
        .dwICC = w32.ICC_TAB_CLASSES,
    };
    _ = w32.InitCommonControlsEx(&icc);
    const tip = w32.CreateWindowExW(
        w32.WS_EX_TOPMOST | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
        w32.TOOLTIPS_CLASS,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.TTS_ALWAYSTIP | w32.TTS_NOPREFIX,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        // UNOWNED, on purpose. Owned by this window, the topmost tooltip
        // dragged its owner up the z-order the moment it was created - and it
        // is created on the first layout of every window, including one
        // opened in the background, which then landed ABOVE the window the
        // user was in (cli-focus-policy.ps1 arm R, measured: new window at
        // z=6 over Ghoztty's frontmost at z=9; unowned, 5 under 4). The tool
        // texts are set directly, so no notification needs a parent.
        null,
        null,
        null,
        null,
    ) orelse return null;
    // A tile's tip is two lines (the title, then the hint): a max width is
    // what makes the control honor the line break at all.
    _ = w32.SendMessageW(tip, w32.TTM_SETMAXTIPWIDTH, 0, pane_sidebar.px(320, self.scale));
    if (self.theme().dark) {
        _ = w32.SetWindowTheme(tip, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    }
    self.tip = tip;
    return tip;
}

fn toolInfo(hwnd: w32.HWND, id: usize, r: pane_sidebar.Rect, text: [*:0]const u16) w32.TOOLINFOW {
    return .{
        .cbSize = @sizeOf(w32.TOOLINFOW),
        .uFlags = w32.TTF_SUBCLASS,
        .hwnd = hwnd,
        .uId = id,
        .rect = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom },
        .hinst = null,
        .lpszText = @ptrCast(@constCast(text)),
        .lParam = 0,
        .lpReserved = null,
    };
}

fn addTool(tip: w32.HWND, hwnd: w32.HWND, id: usize, r: pane_sidebar.Rect, text: [*:0]const u16) void {
    var ti = toolInfo(hwnd, id, r, text);
    // Delete first: re-adding an existing id would leave the old rect live.
    _ = w32.SendMessageW(tip, w32.TTM_DELTOOLW, 0, @bitCast(@intFromPtr(&ti)));
    _ = w32.SendMessageW(tip, w32.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&ti)));
}

fn delTool(tip: w32.HWND, hwnd: w32.HWND, id: usize) void {
    var ti = toolInfo(hwnd, id, .{}, std.unicode.utf8ToUtf16LeStringLiteral(""));
    _ = w32.SendMessageW(tip, w32.TTM_DELTOOLW, 0, @bitCast(@intFromPtr(&ti)));
}

const W = std.unicode.utf8ToUtf16LeStringLiteral;
const tip_collapse = W(tips.toggleTip(true, true));
const tip_expand = W(tips.toggleTip(false, true));
const tip_too_narrow = W(tips.toggleTip(false, false));
const tip_focus = W(tips.rowHint(.grid));
const tip_restore = W(tips.rowHint(.stashed));
const tip_stash_btn = W(tips.buttonTip(.grid));
const tip_restore_btn = W(tips.buttonTip(.stashed));
// Mac's `.help` strings for the all-windows scope (T1829).
const tip_scope_on = W("Show panes from all windows");
const tip_scope_off = W("Show only this window\u{2019}s panes");
const tip_head_this = W("This window \u{2014} click to hide or show its panes");
const tip_head_other = W("Raise this window");
const tip_head_project = W("Hide or show this project\u{2019}s windows");
// In the all-windows list a header also drags (T2337, Mac's help text).
const tip_head_this_drag = W("This window \u{2014} drag to reorder");
const tip_head_other_drag = W("Raise this window \u{2014} drag to reorder");
const tip_head_project_drag = W("Hide or show this project\u{2019}s windows \u{2014} drag to reorder");
const tip_search = W("Search windows and panes \u{2014} every word must match");
const tip_search_clear = W("Clear search");
const tip_close = W(row_menu.close_tip);
const tip_add = W(add_rules.new_window_tip);
const tip_new_pane = W(add_rules.new_pane_tip);
const tip_rename_window = W(rename_rules.tip(.window));
const tip_rename_group = W(rename_rules.tip(.project));
const tip_rename_pane = W(rename_rules.tip(.pane));
const tip_restore_row = W(tips.stashed_row_tip);

/// A header x's tip (Mac's `.help`): "Close window", or a project's "Close
/// its N windows".
/// A header +'s tip: a window's "New pane", a project's "New window in
/// <project>".
fn headAddTip(self: *PaneSidebar, k: usize, hd: pane_sidebar.Head) [*:0]const u16 {
    const buf = &self.head_add_tip_text[k];
    var pb: [name_cap]u8 = undefined;
    var nb: [name_cap + 16]u8 = undefined;
    const text8 = if (hd.kind == .window) add_rules.new_pane_tip else if (self.headProject(hd, &pb)) |project|
        add_rules.projectAddTip(project, &nb)
    else
        add_rules.new_window_tip;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text8[0..@min(text8.len, buf.len - 1)]) catch 0;
    buf[n] = 0;
    return buf[0..n :0];
}

fn headCloseTip(self: *PaneSidebar, k: usize, hd: pane_sidebar.Head) [*:0]const u16 {
    const buf = &self.head_tip_text[k];
    var nb: [40]u8 = undefined;
    const text8 = if (hd.kind == .window) row_menu.close_window_tip else row_menu.projectCloseTip(if (hd.index < self.groups.items.len) self.groups.items[hd.index].project_size else 0, &nb);
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text8) catch 0;
    buf[n] = 0;
    return buf[0..n :0];
}

/// The toggle's tip: what a click does, or why it does nothing.
fn toggleTipText(self: *const PaneSidebar) [*:0]const u16 {
    if (self.mode == .expanded) return tip_collapse;
    return if (self.can_expand) tip_expand else tip_too_narrow;
}

/// Bring the tools in line with the layout. Idempotent; cheap enough for
/// every place/refresh (a handful of tool messages).
fn syncTips(self: *PaneSidebar) void {
    const tip = self.tipEnsure() orelse return;
    const hwnd = self.hwnd;
    // How many rows and tiles got a tip because they are in view (T1878):
    // a scrolled-away row has none. Logged ahead of the counts.
    var in_view: usize = 0;
    const live = self.mode != .hidden;
    const l = self.currentLayout();
    const n = if (live) @min(l.count, self.entries.items.len) else 0;
    // Drop the tools of rows and heads that are gone.
    if (self.tip_items > n) for (n..self.tip_items) |i| {
        delTool(tip, hwnd, toolItem(i));
        delTool(tip, hwnd, toolButton(i));
        delTool(tip, hwnd, toolClose(i));
        delTool(tip, hwnd, toolRowRename(i));
    };
    const nh = if (live) l.head_count else 0;
    if (self.tip_heads > nh) for (nh..self.tip_heads) |k| {
        delTool(tip, hwnd, toolHead(k));
        delTool(tip, hwnd, toolHeadClose(k));
        delTool(tip, hwnd, toolHeadAdd(k));
        delTool(tip, hwnd, toolHeadRename(k));
    };
    self.tip_heads = nh;
    // The search field (T1877, Mac's `.toolTip` and "Clear search"):
    // the field's tip stops short of the clear button, so the two
    // never claim the same point.
    if (live and l.search.width() > 0) {
        var field = l.search;
        if (l.search_text) {
            field.right = l.search_clear.left;
            addTool(tip, hwnd, tool_search_clear, l.search_clear, tip_search_clear);
        } else delTool(tip, hwnd, tool_search_clear);
        addTool(tip, hwnd, tool_search, field, tip_search);
    } else {
        delTool(tip, hwnd, tool_search);
        delTool(tip, hwnd, tool_search_clear);
    }
    // The rail's + (T2324, Mac's "New pane"), while its slot is in view.
    const rail_add = if (live) scroll_mod.visible(&l, l.rail_add) else pane_sidebar.Rect{};
    if (rail_add.height() > 0) addTool(tip, hwnd, tool_rail_add, rail_add, tip_new_pane) else delTool(tip, hwnd, tool_rail_add);
    if (!live) {
        delTool(tip, hwnd, tool_toggle);
        delTool(tip, hwnd, tool_scope);
        delTool(tip, hwnd, tool_add);
    } else {
        addTool(tip, hwnd, tool_toggle, l.toggle, self.toggleTipText());
        const rows = l.mode == .expanded;
        if (rows) {
            addTool(tip, hwnd, tool_scope, l.scope, if (self.all_windows) tip_scope_off else tip_scope_on);
            addTool(tip, hwnd, tool_add, l.add, tip_add);
        } else {
            delTool(tip, hwnd, tool_scope);
            delTool(tip, hwnd, tool_add);
        }
        for (l.heads[0..nh], 0..) |hd, k| {
            const own = hd.index < self.groups.items.len and self.groups.items[hd.index].own;
            const drags = self.all_windows and rows;
            const text = if (hd.kind == .project)
                (if (drags) tip_head_project_drag else tip_head_project)
            else if (own)
                (if (drags) tip_head_this_drag else tip_head_this)
            else if (drags) tip_head_other_drag else tip_head_other;
            // Only the part of a head in view tips (T1878).
            const v = scroll_mod.visible(&l, hd.rect);
            if (v.height() > 0) addTool(tip, hwnd, toolHead(k), v, text) else delTool(tip, hwnd, toolHead(k));
            const x = if (rows) scroll_mod.visible(&l, l.headClose(k, self.scale)) else pane_sidebar.Rect{};
            if (x.height() > 0) {
                addTool(tip, hwnd, toolHeadClose(k), x, self.headCloseTip(k, hd));
            } else delTool(tip, hwnd, toolHeadClose(k));
            const a = if (rows) scroll_mod.visible(&l, l.headAdd(k, self.scale)) else pane_sidebar.Rect{};
            if (a.height() > 0) {
                addTool(tip, hwnd, toolHeadAdd(k), a, self.headAddTip(k, hd));
            } else delTool(tip, hwnd, toolHeadAdd(k));
            const pr = if (rows) scroll_mod.visible(&l, l.headRename(k, self.scale)) else pane_sidebar.Rect{};
            if (pr.height() > 0) {
                addTool(tip, hwnd, toolHeadRename(k), pr, if (hd.kind == .project) tip_rename_group else tip_rename_window);
            } else delTool(tip, hwnd, toolHeadRename(k));
        }
        for (self.entries.items[0..n], 0..) |e, i| {
            if (!l.shown(i) or scroll_mod.visible(&l, l.items[i]).height() <= 0) {
                // Folded away, or scrolled out of view (T1878): no
                // row on screen, so no tip.
                delTool(tip, hwnd, toolItem(i));
                delTool(tip, hwnd, toolButton(i));
                delTool(tip, hwnd, toolClose(i));
                delTool(tip, hwnd, toolRowRename(i));
                continue;
            }
            if (rows) {
                // Only this window's stashed rows can swap (T1845).
                const row_tip = if (e.section != .stashed) tip_focus else if (e.own) tip_restore_row else tip_restore;
                addTool(tip, hwnd, toolItem(i), scroll_mod.visible(&l, l.items[i]), row_tip);
                in_view += 1;
                const btn_tip = if (e.section == .stashed) tip_restore_btn else tip_stash_btn;
                const b = scroll_mod.visible(&l, l.rowButton(i, self.scale));
                if (b.height() > 0) addTool(tip, hwnd, toolButton(i), b, btn_tip) else delTool(tip, hwnd, toolButton(i));
                const x = scroll_mod.visible(&l, l.rowClose(i, self.scale));
                if (x.height() > 0) addTool(tip, hwnd, toolClose(i), x, tip_close) else delTool(tip, hwnd, toolClose(i));
                const pr = scroll_mod.visible(&l, l.rowRename(i, self.scale));
                if (pr.height() > 0) addTool(tip, hwnd, toolRowRename(i), pr, tip_rename_pane) else delTool(tip, hwnd, toolRowRename(i));
            } else {
                // Another window's tile names its window too (Mac: "in
                // the mini rail ... the hover label names the window").
                var named: [tips.tip_cap]u16 = undefined;
                const title = self.tileTitle(e, &named);
                const len = tips.tileTip(&self.tip_text[i], title, e.section);
                addTool(tip, hwnd, toolItem(i), scroll_mod.visible(&l, l.items[i]), self.tip_text[i][0..len :0]);
                in_view += 1;
                delTool(tip, hwnd, toolButton(i));
                delTool(tip, hwnd, toolClose(i));
            }
        }
    }
    self.tip_items = n;
    // The line keeps its two-surface shape (`view=<rail>,<card>`,
    // `rail=<n>`): the hover-open card was the second surface until
    // T2289, and the scripts read the line as it was. The toggle's
    // tip text rides at the end, so a script can tell a disabled
    // rail button from an enabled one.
    var full: [300]u8 = undefined;
    const toggle8 = if (self.mode == .expanded) tips.toggleTip(true, true) else tips.toggleTip(false, self.can_expand);
    const counts = std.fmt.bufPrint(&full, " view={d},0 rail={d} toggle=\"{s}\"", .{ in_view, if (live) n + 1 else 0, toggle8 }) catch "";
    self.logTips(counts);
}

/// The tooltip set, once per CHANGE, for the acceptance script: tools are
/// windows of comctl32's that a background desktop can never show, so what is
/// scored is that every tile, row and the toggle got one.
fn logTips(self: *PaneSidebar, counts: []const u8) void {
    // The first tile's text, so the script can check it names the pane. Part
    // of what is compared: the same counts in another mode is another set.
    var first: [tips.tip_cap * 3]u8 = undefined;
    var first_len: usize = 0;
    if (self.mode == .mini and self.tip_items > 0) {
        const t = std.mem.sliceTo(&self.tip_text[0], 0);
        first_len = std.unicode.utf16LeToUtf8(&first, t) catch 0;
        for (first[0..first_len]) |*ch| if (ch.* == 0x0A) {
            ch.* = '|';
        };
    }
    var buf: [tips.tip_cap * 3 + 256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} mode={s} tile0={s}", .{ counts, @tagName(self.mode), first[0..first_len] }) catch counts;
    const key = line[0..@min(line.len, self.tip_log.len)];
    if (key.len == self.tip_log_len and std.mem.eql(u8, self.tip_log[0..self.tip_log_len], key)) return;
    @memcpy(self.tip_log[0..key.len], key);
    self.tip_log_len = key.len;
    log.debug("pane sidebar tips{s}", .{line});
}

/// A rail tile's tip title: the pane's, and for another window's pane also
/// " \u{2014} <window>".
fn tileTitle(self: *const PaneSidebar, e: Entry, buf: *[tips.tip_cap]u16) []const u16 {
    if (e.own or e.group >= self.groups.items.len) return e.title;
    const label = self.groups.items[e.group].label;
    const sep = std.unicode.utf8ToUtf16LeStringLiteral(" \u{2014} ");
    var n: usize = 0;
    for ([_][]const u16{ e.title, sep, label }) |part| {
        const take = @min(part.len, buf.len - n);
        @memcpy(buf[n .. n + take], part[0..take]);
        n += take;
    }
    return buf[0..n];
}

/// `alt`: Alt was down on the click (Mac's Option-click swap, T1845).
fn activate(self: *PaneSidebar, hit: pane_sidebar.Hit, alt: bool) void {
    switch (hit) {
        .none => {},
        // A disabled rail toggle (a window too narrow for the panel) takes
        // the click and does nothing, as Mac's `.disabled` button does.
        .toggle => if (self.toggleEnabled()) self.window.setPaneSidebarExpanded(self.mode != .expanded, if (self.mode == .expanded) "header button" else "rail button"),
        .scope => self.toggleScope(),
        // The header's + (T2323): Ctrl+Shift+N from this window.
        .add => self.window.app.newWindowFromSidebar(self.window, null),
        .search => self.focusSearch(),
        .search_clear => {
            log.info("pane sidebar search cleared by button", .{});
            self.searchEdited(self.search.clear());
        },
        .item => |i| {
            if (i >= self.entries.items.len) return;
            const e = self.entries.items[i];
            switch (row_menu.clickVerb(e.section, e.own, alt)) {
                .focus, .restore => self.window.paneSidebarActivate(e.pane),
                .exchange => self.window.paneSidebarExchange(e.pane),
                .reveal => self.focusForeign(e),
            }
        },
        .item_button => |i| {
            if (i >= self.entries.items.len) return;
            const e = self.entries.items[i];
            // Only this window's rows have one (`rowOffersStash`).
            if (row_menu.rowOffersStash(e.own)) self.window.paneSidebarToggleStash(e.pane);
        },
        // The x (T2280, T2298): close the pane, in this window or another,
        // asking nothing and taking no focus. That can close this very
        // window (its last pane), so nothing here is touched after.
        .item_close => |i| {
            if (i >= self.entries.items.len) return;
            const e = self.entries.items[i];
            const w = self.rowWindow(e) orelse return;
            return w.paneSidebarCloseNow(e.pane);
        },
        .head, .head_fold => |k| self.activateHead(k, std.meta.activeTag(hit) == .head_fold),
        .head_close => |k| self.closeHead(k),
        .head_add => |k| self.addFromHead(k),
        // The pencils (T2339): the name turns into a field.
        .item_rename => |i| self.beginRenamePane(i),
        .head_rename => |k| self.beginRenameHead(k),
        // The rail's + (T2324): this window's header's own +.
        .rail_add => if (self.groups.items.len > 0) self.addPaneIn(self.groups.items[0]),
    }
}

/// The all-windows switch (T1829). Nothing is persisted. Each look starts
/// from the default folds (T1924): this window open, every other folded.
/// Project folds survive a round trip, as Mac's do.
fn toggleScope(self: *PaneSidebar) void {
    // Started before the switch, so the paint the refresh below brings is
    // already the transition's first frame rather than the new list.
    self.startTransition(self.snapshot(.{ .scope = !self.all_windows }));
    // The list the field sat in is going: what was typed is kept (T2339).
    if (self.rename != null) self.endRename(true, "scope");
    // One switch for every window (T2336). On opens this window's group and
    // folds every other; off, the search belongs to the scope (Mac clears
    // the filter with it): the field is gone, so its query and its caret go
    // too - and so do the window folds the user flipped.
    _ = shared.setAllWindows(self.alloc, !self.all_windows, tabKey(self.window, self.window.active_tab));
    self.published();
    self.hover = .none;
    self.syncHoverTint();
    self.signature = 0;
    if (!self.all_windows) {
        if (self.search_focus) self.releaseSearchFocus();
    }
    log.info("pane sidebar scope all_windows={}", .{self.all_windows});
    self.refresh();
    self.takeScroll();
}

// -------------------------------------------------------------------------
// The all-windows search field (T1877)
// -------------------------------------------------------------------------

/// The field is on screen: the all-windows scope, in the panel (the rail has
/// no room for it).
fn searchShown(self: *const PaneSidebar) bool {
    return self.all_windows and self.mode == .expanded;
}

/// A click in the field: the column takes the keyboard. Through the loop's
/// deferred focus (T48) like every other focus move - never a synchronous
/// SetFocus from inside a click. A click that did not activate the window
/// (another app in front) brings it forward first, or the keys would go to
/// that app.
fn focusSearch(self: *PaneSidebar) void {
    if (!self.searchShown()) return;
    if (w32.GetAncestor(self.hwnd, w32.GA_ROOT)) |root| {
        if (!w32.windowIsActive(root)) _ = w32.SetForegroundWindow(root);
    }
    App.deferSetFocus(self.hwnd);
    self.repaint();
}

/// Give the caret back to this window's focused pane (Mac: Escape on an empty
/// field resigns it).
fn releaseSearchFocus(self: *PaneSidebar) void {
    // Cleared up front, not on the WM_KILLFOCUS the deferred move brings:
    // the activation below relays the window out, which places this column
    // again, and that must not ask for the release a second time.
    self.search_focus = false;
    self.repaint();
    if (w32.GetFocus() != self.hwnd) return;
    log.info("pane sidebar search released the caret", .{});
    if (self.window.getActivePane()) |p| self.window.paneSidebarActivate(p);
}

/// The query or the caret changed: re-filter when the text did, repaint
/// either way.
fn searchEdited(self: *PaneSidebar, text_changed: bool) void {
    // The query is every window's (T2336); the others take it when they
    // are next activated.
    shared.search = self.search;
    shared.searchEdited();
    self.seen_gen = shared.gen;
    if (text_changed and self.all_windows) self.refresh();
    self.repaint();
}

/// Return in the field: go to the first hit, as clicking its row would (Mac
/// `revealFirstMatch`). Searching, the roster IS the hits in outline order.
fn submitSearch(self: *PaneSidebar) void {
    if (!self.filterActive() or self.entries.items.len == 0) return;
    log.info("pane sidebar search reveal first hit own={}", .{self.entries.items[0].own});
    self.activate(.{ .item = 0 }, false);
}

/// A key while the column holds the keyboard. True when the field used it.
fn searchKey(self: *PaneSidebar, vk: u16, wparam: usize, lparam: isize) bool {
    const ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
    const shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
    switch (vk) {
        w32.VK_RETURN => self.submitSearch(),
        w32.VK_ESCAPE => switch (search_field.escapeVerb(self.search.isEmpty())) {
            .clear => {
                log.info("pane sidebar search cleared by escape", .{});
                self.searchEdited(self.search.clear());
            },
            .release => self.releaseSearchFocus(),
        },
        w32.VK_BACK => self.searchEdited(self.search.backspace(ctrl)),
        w32.VK_DELETE => self.searchEdited(self.search.delete(ctrl)),
        w32.VK_LEFT, w32.VK_RIGHT, w32.VK_HOME, w32.VK_END => {
            const m: search_field.Move = switch (vk) {
                w32.VK_LEFT => if (ctrl) .word_left else .left,
                w32.VK_RIGHT => if (ctrl) .word_right else .right,
                w32.VK_HOME => .home,
                else => .end,
            };
            if (self.search.move(m)) self.repaint();
        },
        'V' => {
            if (!ctrl) return false;
            self.pasteSearch();
        },
        else => {
            // The window's own chords (Ctrl+Shift+...) still work with the
            // caret here, as they do from the tab-rename and palette edits.
            // Plain Ctrl chords stay with the field: Ctrl+C or Ctrl+D handed
            // to a shell would interrupt or end it.
            if (!(ctrl and shift)) return false;
            const s = self.window.getActiveSurface() orelse return false;
            s.handleKeyEvent(wparam, lparam, .press);
        },
    }
    return true;
}

/// Ctrl+V: the clipboard's text, as one line (`Field.insert`).
fn pasteSearch(self: *PaneSidebar) void {
    if (w32.OpenClipboard(self.hwnd) == 0) return;
    defer _ = w32.CloseClipboard();
    const mem = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return;
    const p = w32.GlobalLock(mem) orelse return;
    defer _ = w32.GlobalUnlock(mem);
    const units: [*]const u16 = @ptrCast(@alignCast(p));
    var n: usize = 0;
    while (n < 4 * search_field.cap and units[n] != 0) n += 1;
    self.searchEdited(self.search.insert(units[0..n]));
}

// -------------------------------------------------------------------------
// Rename in place (T2339; Mac 379a352ef, a13bf6f43)
// -------------------------------------------------------------------------

/// A terminal row's pencil: the field opens on the name the row shows.
fn beginRenamePane(self: *PaneSidebar, i: usize) void {
    if (i >= self.entries.items.len) return;
    const e = self.entries.items[i];
    if (!rename_rules.offersPencil(.pane, e.pane.isViewer())) return;
    var b: [Rename.initial_cap]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&b, e.title[0..@min(e.title.len, search_field.cap)]) catch 0;
    self.beginRename(.{ .pane = e.pane }, b[0..n]);
}

/// A header's pencil: a window's field opens on its whole title,
/// `<project>: ` included; a project's on the project as its titles spell it.
fn beginRenameHead(self: *PaneSidebar, k: usize) void {
    const l = self.currentLayout();
    if (k >= l.head_count) return;
    const hd = l.heads[k];
    if (hd.index >= self.groups.items.len) return;
    const g = self.groups.items[hd.index];
    if (!self.window.app.hasWindow(g.window) or g.tab >= g.window.tab_count) return;
    var b: [name_cap]u8 = undefined;
    switch (hd.kind) {
        .window => self.beginRename(.{ .window = g.key }, groupName(g.window, g.tab, &b)),
        .project => {
            const project = self.headProject(hd, &b) orelse return;
            self.beginRename(.{ .project = g.project_key }, project);
        },
    }
}

/// Open the field on `initial8`, selected, and give it the keyboard - through
/// the loop's deferred focus (T48), as the search field takes it.
fn beginRename(self: *PaneSidebar, target: RenameTarget, initial8: []const u8) void {
    if (self.mode != .expanded) return;
    // One field at a time: another open one keeps what it holds.
    if (self.rename != null) self.endRename(true, "another");
    // The caret moves from the search field to this one.
    if (self.search_focus) self.search_focus = false;
    self.rename = .{ .target = target };
    const r = &self.rename.?;
    const n = fitUtf8(initial8, r.initial.len);
    @memcpy(r.initial[0..n], initial8[0..n]);
    r.initial_len = n;
    var units: [search_field.cap]u16 = undefined;
    r.field.setSelected(toUnits(&units, initial8));
    log.info("pane sidebar rename begin kind={s} text={s}", .{ @tagName(target), r.initialText() });
    if (w32.GetAncestor(self.hwnd, w32.GA_ROOT)) |root| {
        if (!w32.windowIsActive(root)) _ = w32.SetForegroundWindow(root);
    }
    App.deferSetFocus(self.hwnd);
    self.repaint();
}

/// Close the field: `commit` applies what was typed (Return, clicking away),
/// otherwise nothing changes (Escape, the item went away). Cleared FIRST:
/// the renames below refresh every sidebar, this one included, and a focus
/// move can arrive while they do.
fn endRename(self: *PaneSidebar, commit: bool, why: []const u8) void {
    const r = self.rename orelse return;
    self.rename = null;
    self.repaint();
    var tb: [search_field.cap * 3]u8 = undefined;
    const typed = r.field.utf8(&tb);
    const outcome: rename_rules.Outcome = if (commit) rename_rules.decide(typed, r.initialText()) else .keep;
    log.info("pane sidebar rename end why={s} kind={s} outcome={s} text={s}", .{ why, @tagName(r.target), @tagName(outcome), typed });
    const name: ?[]const u8 = switch (outcome) {
        .keep => return,
        .clear => null,
        .set => |v| v,
    };
    const app = self.window.app;
    switch (r.target) {
        .pane => |p| renamePane(app, p, name),
        .window => |key| renameWindowGroup(app, key, name),
        .project => |key| {
            // The fold follows the group to its new name, as its windows do.
            // One set for every window's sidebar (T2336).
            if (name) |nm| if (shared.folded_projects.contains(key)) {
                shared.toggleProject(self.alloc, key);
                const to = projectKey(nm);
                if (!shared.folded_projects.contains(to)) shared.toggleProject(self.alloc, to);
                self.published();
            };
            if (name) |nm| self.keepProjectPlace(r.initialText(), nm);
            renameProject(app, r.initialText(), name orelse "");
        },
    }
    // Any window rename redraws every sidebar (Mac `PaneRoster.changed`).
    refreshScopes(app.windows.items, null);
}

/// A renamed group keeps its place in the all-windows list's order (T2339's
/// rule, carried by T2338; Mac `renameGroupFromSidebar`): its new name takes
/// the old one's key where it stood.
fn keepProjectPlace(self: *PaneSidebar, old: []const u8, new: []const u8) void {
    var cur_buf: [window_order.max_keys][]const u8 = undefined;
    const cur = shared.windowOrder(&cur_buf);
    if (cur.len == 0) return;
    const old_key = window_order.projectKey(old);
    const new_key = window_order.projectKey(new);
    var out: [window_order.max_keys][]const u8 = undefined;
    const n = cross_drop.renamedProject(cur, old_key.slice(), new_key.slice(), new.len == 0, &out);
    if (!shared.setWindowOrder(self.alloc, out[0..n])) return;
    var saved: [window_order.max_keys][]const u8 = undefined;
    window_order.save(self.alloc, shared.windowOrder(&saved));
    log.info("pane sidebar window order kept a renamed group's place from={s} to={s}", .{ old, new });
}

/// A pane's name, as Change Pane Title sets it: pinned against the
/// terminal's own titles, `null` back to them. Found again among the live
/// windows first - the field may have outlived the pane.
fn renamePane(app: *App, p: *PaneView, name: ?[]const u8) void {
    for (app.windows.items) |w| {
        if (w.findTabIndex(p) == null) continue;
        if (p.surface()) |s| s.setUserTitle(name);
        return;
    }
}

/// A window group's name (Mac `setWindowTitle`). A Mac window is a tab here,
/// so it is the tab's title that is pinned - unless the window carries a
/// window-wide pin, which is what its rows show and so what was edited.
fn pinWindowName(w: *Window, t: usize, name: ?[]const u8) void {
    if (w.title_override) |o| if (o.len > 0) return w.setTitleOverride(name);
    w.setTabTitlePin(t, name);
}

fn renameWindowGroup(app: *App, key: u64, name: ?[]const u8) void {
    for (app.windows.items) |w| for (0..w.tab_count) |t| {
        if (tabKey(w, t) != key) continue;
        return pinWindowName(w, t, name);
    };
}

/// A project group renamed from `old` to `project` (Mac
/// `renameGroupFromSidebar`): each of its windows becomes `<project>: <name>`
/// - or, emptied, just `<name>`.
fn renameProject(app: *App, old: []const u8, project: []const u8) void {
    for (app.windows.items) |w| for (0..w.tab_count) |t| {
        var nb: [name_cap]u8 = undefined;
        const split = outline.splitWindowTitle(groupName(w, t, &nb)) orelse continue;
        if (!std.mem.eql(u8, split.project, old)) continue;
        var tb: [name_cap + 64]u8 = undefined;
        // Copied before the pin replaces the title it was read from.
        pinWindowName(w, t, rename_rules.groupTitle(&tb, project, split.worktree));
    };
}

/// Whether what the field edits is still listed here.
fn renameTargetLive(self: *const PaneSidebar) bool {
    const r = if (self.rename) |*x| x else return false;
    switch (r.target) {
        .pane => |p| for (self.entries.items) |e| {
            if (e.pane == p) return true;
        },
        .window => |key| for (self.groups.items) |g| {
            if (g.key == key) return true;
        },
        .project => |key| for (self.groups.items) |g| {
            if (g.project.len > 0 and g.project_key == key) return true;
        },
    }
    return false;
}

fn renamingPane(self: *const PaneSidebar, p: *const PaneView) bool {
    const r = if (self.rename) |*x| x else return false;
    return switch (r.target) {
        .pane => |q| q == p,
        else => false,
    };
}

fn renamingHead(self: *const PaneSidebar, hd: pane_sidebar.Head, g: Group) bool {
    const r = if (self.rename) |*x| x else return false;
    return switch (r.target) {
        .window => |key| hd.kind == .window and g.key == key,
        .project => |key| hd.kind == .project and g.project_key == key,
        .pane => false,
    };
}

/// Whether (`x`, `y`) is in the open field, as last painted.
fn inRenameField(self: *const PaneSidebar, x: i32, y: i32) bool {
    const r = if (self.rename) |*v| v else return false;
    return r.box.width() > 0 and renameWell(r.box, self.scale).contains(x, y);
}

/// The field's well round its text box: a step out on each side, so the
/// text sits where the name it replaces sat.
fn renameWell(box: pane_sidebar.Rect, scale: f32) pane_sidebar.Rect {
    const pad = pane_sidebar.px(4, scale);
    const v = pane_sidebar.px(2, scale);
    return .{ .left = box.left - pad, .top = box.top - v, .right = box.right, .bottom = box.bottom + v };
}

/// How far the field's text is scrolled left so its caret stays in view.
fn renameScroll(r: *const Rename, hdc: w32.HDC) i32 {
    const caret_x = textWidth(hdc, r.field.text()[0..r.field.caret]);
    return search_field.scrollFor(caret_x, r.box.width() - 1);
}

/// The field (T2339): the search field's input shape - a rounded well a step
/// off what it sits on, the accent underline while it holds the keyboard -
/// with the text selected as it opens, then a caret.
fn paintRenameField(self: *PaneSidebar, hdc: w32.HDC, box: pane_sidebar.Rect, font: ?*anyopaque, under: color_math.Rgb, t: Theme) void {
    const r = if (self.rename) |*x| x else return;
    r.box = box;
    r.font = font;
    const s = self.scale;
    const well_r = renameWell(box, s);
    const radius = pane_sidebar.px(4, s);
    const well = shade(under, if (t.dark) -14 else 14);
    fillRound(hdc, well_r, radius, rgb(well));
    const focused = w32.GetFocus() == self.hwnd;
    if (focused) {
        const line = @max(pane_sidebar.px(2, s), 1);
        fillRect(hdc, .{ .left = well_r.left + radius, .top = well_r.bottom - line, .right = well_r.right - radius, .bottom = well_r.bottom }, rgb(t.accent));
    }
    const text = r.field.text();
    const off = renameScroll(r, hdc);
    const saved = w32.SaveDC(hdc);
    _ = w32.IntersectClipRect(hdc, box.left, well_r.top, box.right, well_r.bottom);
    if (r.field.all) {
        const sel_w = textWidth(hdc, text);
        fillRect(hdc, .{ .left = box.left - off, .top = box.top, .right = box.left - off + sel_w, .bottom = box.bottom }, rgb(color_math.mix(well, t.accent, 0.45)));
    }
    drawText(hdc, text, .{ .left = box.left - off, .top = box.top, .right = box.left - off + 100000, .bottom = box.bottom }, t.text, w32.DT_VCENTER);
    _ = w32.RestoreDC(hdc, saved);
    if (focused and !r.field.all) {
        const cx = box.left + textWidth(hdc, text[0..r.field.caret]) - off;
        fillRect(hdc, .{ .left = cx, .top = box.top, .right = cx + @max(pane_sidebar.px(1, s), 1), .bottom = box.bottom }, t.text);
    }
}

/// A press in the field at `x`: the caret goes to the nearest boundary,
/// measured the way `paintRenameField` lays the text out.
fn renameClick(self: *PaneSidebar, x: i32) void {
    const r = if (self.rename) |*v| v else return;
    const dc = w32.CreateCompatibleDC(null) orelse return;
    defer _ = w32.DeleteDC(dc);
    if (r.font) |f| _ = w32.SelectObject(dc, @ptrCast(f));
    // Measured as painted: before the click ends a selection, the text has
    // not scrolled for a caret it did not show.
    const off = renameScroll(r, dc);
    const text = r.field.text();
    const target = x - r.box.left + off;
    var at: usize = text.len;
    var prev: i32 = 0;
    for (1..text.len + 1) |i| {
        const wdt = textWidth(dc, text[0..i]);
        if (wdt >= target) {
            at = if (target - prev < wdt - target) i - 1 else i;
            break;
        }
        prev = wdt;
    }
    r.field.setCaret(at);
    // Clicked back into it after the keyboard went elsewhere: take it again.
    if (w32.GetFocus() != self.hwnd) App.deferSetFocus(self.hwnd);
    self.repaint();
}

/// A key while a name is being edited. True when the field used it.
fn renameKey(self: *PaneSidebar, vk: u16, wparam: usize, lparam: isize) bool {
    _ = wparam;
    _ = lparam;
    const r = if (self.rename) |*v| v else return false;
    const ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
    switch (vk) {
        w32.VK_RETURN, w32.VK_ESCAPE => {
            self.endRename(vk == w32.VK_RETURN, if (vk == w32.VK_RETURN) "return" else "escape");
            // Done with the keyboard: back to this window's focused pane, as
            // the search field gives it back.
            if (w32.GetFocus() == self.hwnd) {
                if (self.window.getActivePane()) |p| self.window.paneSidebarActivate(p);
            }
            return true;
        },
        w32.VK_BACK => if (r.field.backspace(ctrl)) self.repaint(),
        w32.VK_DELETE => if (r.field.delete(ctrl)) self.repaint(),
        w32.VK_LEFT, w32.VK_RIGHT, w32.VK_HOME, w32.VK_END => {
            const m: search_field.Move = switch (vk) {
                w32.VK_LEFT => if (ctrl) .word_left else .left,
                w32.VK_RIGHT => if (ctrl) .word_right else .right,
                w32.VK_HOME => .home,
                else => .end,
            };
            if (r.field.move(m)) self.repaint();
        },
        'A' => {
            if (!ctrl) return false;
            r.field.selectAll();
            self.repaint();
        },
        'V' => {
            if (!ctrl) return false;
            var units: [search_field.cap]u16 = undefined;
            if (r.field.insert(self.clipboardText(&units))) self.repaint();
        },
        else => return false,
    }
    return true;
}

/// The clipboard's text, up to `out.len` units (empty when there is none).
fn clipboardText(self: *PaneSidebar, out: []u16) []const u16 {
    if (w32.OpenClipboard(self.hwnd) == 0) return out[0..0];
    defer _ = w32.CloseClipboard();
    const mem = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return out[0..0];
    const p = w32.GlobalLock(mem) orelse return out[0..0];
    defer _ = w32.GlobalUnlock(mem);
    const units: [*]const u16 = @ptrCast(@alignCast(p));
    var n: usize = 0;
    while (n < out.len and units[n] != 0) : (n += 1) out[n] = units[n];
    return out[0..n];
}

/// `s` (valid UTF-8: every caller converted it) as UTF-16 into `out`, as
/// much as fits whole.
fn toUnits(out: []u16, s: []const u8) []const u16 {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            if (n + 2 > out.len) break;
            const v = cp - 0x10000;
            out[n] = @intCast(0xD800 + (v >> 10));
            out[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        } else {
            if (n + 1 > out.len) break;
            out[n] = @intCast(cp);
            n += 1;
        }
    }
    return out[0..n];
}

/// How many leading bytes of `s` fit in `room` without cutting a character.
fn fitUtf8(s: []const u8, room: usize) usize {
    if (s.len <= room) return s.len;
    var n = room;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// The window an entry's pane lives in, if it is still open: this sidebar's
/// own, or - for another window's row - that one, asked about first.
fn rowWindow(self: *PaneSidebar, e: Entry) ?*Window {
    if (e.own) return self.window;
    if (!self.window.app.hasWindow(e.window)) return null;
    return e.window;
}

/// A row's or tile's right-click menu (T1845, Mac `PaneSidebarRow
/// .contextMenu`). The menu's modal loop pumps messages, so the roster can be
/// rebuilt while it is up: the pane and its window are captured first and
/// asked about again before the chosen command runs.
fn openRowMenu(self: *PaneSidebar, hwnd: w32.HWND, i: usize, x: i32, y: i32) void {
    if (i >= self.entries.items.len) return;
    const e = self.entries.items[i];
    const w = self.rowWindow(e) orelse return;
    var items: [row_menu.max_items]row_menu.Item = undefined;
    const list = row_menu.build(.{
        .section = e.section,
        .own = e.own,
        .can_stash = w.paneSidebarCanStash(e.pane),
        .can_pop_out = w.paneSidebarCanPopOut(e.pane),
    }, &items);

    const popup = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(popup);
    for (list) |item| switch (item) {
        .separator => _ = w32.AppendMenuW(popup, w32.MF_SEPARATOR, 0, null),
        .cmd => |c| {
            var wbuf: [64]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], c.title) catch continue;
            wbuf[n] = 0;
            var flags: u32 = w32.MF_STRING;
            if (!c.enabled) flags |= w32.MF_GRAYED;
            _ = w32.AppendMenuW(popup, flags, @intFromEnum(c.id), @ptrCast(&wbuf));
        },
    };

    var pt = w32.POINT{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &pt);
    log.info("pane sidebar row menu open section={s} own={}", .{ @tagName(e.section), e.own });
    const cmd = w32.TrackPopupMenuEx(
        popup,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD | w32.TPM_RIGHTBUTTON,
        pt.x,
        pt.y,
        hwnd,
        null,
    );

    const id = std.meta.intToEnum(row_menu.Id, @as(usize, @intCast(cmd))) catch return; // 0 = dismissed
    // Still open, and the pane still in it?
    if (!self.window.app.hasWindow(w) or w.findTabIndex(e.pane) == null) return;
    log.info("pane sidebar row menu choice={s}", .{@tagName(id)});
    switch (id) {
        .restore => if (e.own) w.paneSidebarActivate(e.pane) else self.focusForeign(e),
        .exchange => w.paneSidebarExchange(e.pane),
        .stash => w.paneSidebarToggleStash(e.pane),
        .show => self.focusForeign(e),
        .pop_out => w.paneSidebarPopOut(e.pane),
        // The x's close (T2298): no confirmation, no focus taken. May free
        // the pane, and close its window: nothing after.
        .close => w.paneSidebarCloseNow(e.pane),
    }
}

/// A header click: a project header folds its windows; a window header's
/// chevron - or THIS window's header anywhere - folds its panes; another
/// window's header raises that window (Mac `PaneSidebarWindowHeader`).
fn activateHead(self: *PaneSidebar, k: usize, fold: bool) void {
    const l = self.currentLayout();
    if (k >= l.head_count) return;
    const hd = l.heads[k];
    if (hd.index >= self.groups.items.len) return;
    const g = self.groups.items[hd.index];
    if (hd.kind == .project or fold or g.own) self.startTransition(self.snapshot(.{ .fold = .{
        .head = k,
        .y0 = hd.rect.bottom,
        .bottom = scroll_mod.contentBottom(&l, l.viewport.top),
        .scroll = l.scroll,
    } }));
    if (hd.kind == .project) return self.toggleFold(.project, g.project_key);
    if (fold or g.own) return self.toggleFold(.window, g.key);
    self.raiseGroup(g);
}

/// A header's x (T2298, Mac 345be6b02): a window's closes that window - the
/// tab, when its window has others - and a project's every window it shows
/// (while searching, only the matching ones it counts). Nothing is asked and
/// no window is raised; the sessions end, undoable as one close.
///
/// The targets are captured before anything closes: each close rebuilds this
/// roster, and one of them may be this sidebar's own window. The closes
/// themselves run on the next loop turn (`App.closeTabsQuietly`), so a window
/// can close itself from its own sidebar.
fn closeHead(self: *PaneSidebar, k: usize) void {
    const l = self.currentLayout();
    if (k >= l.head_count) return;
    const hd = l.heads[k];
    if (hd.index >= self.groups.items.len) return;
    const head = self.groups.items[hd.index];
    var targets: [pane_sidebar.max_heads]App.QuietClose = undefined;
    var n: usize = 0;
    for (self.groups.items) |g| {
        const mine = if (hd.kind == .project) g.project_key == head.project_key else g.key == head.key;
        if (!mine or n == targets.len) continue;
        if (g.tab >= g.window.tab_count) continue;
        targets[n] = .{ .window = g.window, .tab = g.window.tab_uuid[g.tab] };
        n += 1;
    }
    log.info("pane sidebar close {s} windows={d}", .{ @tagName(hd.kind), n });
    self.window.app.closeTabsQuietly(targets[0..n]);
}

/// A header's + (T2323, Mac 44aa923f0). A project's opens a new window from
/// the group's first window as listed, titled into the group under a free
/// placeholder name - checked against every window at click time, so two
/// quick clicks never share one. A window's raises that window and splits
/// its focused pane the way the user last split one by hand. Both take focus,
/// as Ctrl+Shift+N / a split keybind would.
fn addFromHead(self: *PaneSidebar, k: usize) void {
    const l = self.currentLayout();
    if (k >= l.head_count) return;
    const hd = l.heads[k];
    if (hd.index >= self.groups.items.len) return;
    const g = self.groups.items[hd.index];
    if (!self.window.app.hasWindow(g.window)) return;
    if (hd.kind == .window) return self.addPaneIn(g);
    var pb: [name_cap]u8 = undefined;
    const project = self.headProject(hd, &pb) orelse return;
    var names: [pane_sidebar.max_heads][name_cap]u8 = undefined;
    var taken: [pane_sidebar.max_heads][]const u8 = undefined;
    var n: usize = 0;
    for (self.window.app.windows.items) |w| for (0..w.tab_count) |t| {
        if (n == taken.len) break;
        // `groupName` may hand back the window's own string: copy it.
        const name = groupName(w, t, &names[n]);
        const c = @min(name.len, name_cap);
        if (name.ptr != &names[n]) std.mem.copyForwards(u8, names[n][0..c], name[0..c]);
        taken[n] = names[n][0..c];
        n += 1;
    };
    var tb: [name_cap + 16]u8 = undefined;
    const title = add_rules.newWindowTitle(&tb, project, taken[0..n]);
    if (title.len == 0) return;
    self.window.app.newWindowFromSidebar(g.window, title);
}

/// A window's + - its header's, or the rail's slot (T2324): raise the window
/// and split its focused pane the way the user last split one by hand.
fn addPaneIn(self: *PaneSidebar, g: Group) void {
    if (!self.window.app.hasWindow(g.window)) return;
    const dir = add_rules.split_memory.last;
    log.info("pane sidebar add pane dir={s}", .{@tagName(dir)});
    self.raiseGroup(g);
    _ = g.window.newSplit(add_rules.as(Window.SplitDirection, dir)) catch |err| {
        log.err("pane sidebar add pane failed err={}", .{err});
    };
}

/// A project head's project as the window title spells it (the header shows
/// it upper-cased): read again from its first window's name.
fn headProject(self: *const PaneSidebar, hd: pane_sidebar.Head, buf: *[name_cap]u8) ?[]const u8 {
    if (hd.kind != .project or hd.index >= self.groups.items.len) return null;
    const g = self.groups.items[hd.index];
    if (!self.window.app.hasWindow(g.window) or g.tab >= g.window.tab_count) return null;
    const name = groupName(g.window, g.tab, buf);
    const split = outline.splitWindowTitle(name) orelse return null;
    return split.project;
}

/// Flip a project's fold, or a window group's (`groupFolded`) - in every
/// window's list (T2336).
fn toggleFold(self: *PaneSidebar, kind: enum { project, window }, key: u64) void {
    switch (kind) {
        .project => shared.toggleProject(self.alloc, key),
        .window => shared.toggleGroup(self.alloc, self.all_windows, key),
    }
    self.published();
    const folded = switch (kind) {
        .project => self.folded_projects.contains(key),
        .window => self.groupFolded(key, self.filterActive()),
    };
    log.info("pane sidebar {s}", .{if (folded) "fold" else "unfold"});
    self.refresh();
}

/// Raise another window and show the tab the group is (`ghoztty://focus`'s
/// own verb, `IpcHandlers.focusTarget`). The tab is found again by its
/// identity: tabs reorder, and the window may have closed since the refresh.
fn raiseGroup(self: *PaneSidebar, g: Group) void {
    if (!self.window.app.hasWindow(g.window)) return;
    const w = g.window;
    const tab = for (0..w.tab_count) |t| {
        if (tabKey(w, t) == g.key) break t;
    } else return;
    log.info("pane sidebar raise window tab={d} active={d}", .{ tab, w.active_tab });
    IpcHandlers.focusTarget(.{ .window = w });
    if (tab != w.active_tab) w.selectTabIndex(tab);
}

/// Another window's row: raise that window and focus the pane - restoring it
/// there if it is stashed, selecting its tab if it is in the background - the
/// same verb as `ghoztty://focus` (Mac `IPCServer.focusTarget`).
fn focusForeign(self: *PaneSidebar, e: Entry) void {
    if (!self.window.app.hasWindow(e.window)) return;
    if (e.window.tabIndexOfPane(e.pane) == null) return;
    log.info("pane sidebar focus other window section={s}", .{@tagName(e.section)});
    // Drawn selected here at once (T2336, Mac `clickedPane`), while its
    // window comes forward.
    self.clicked = e.pane;
    self.signature = 0;
    IpcHandlers.focusTarget(.{ .pane = e.pane });
    self.refresh();
}

/// Alt, from the queue's key state as of the message being handled - mouse
/// messages carry no MK_ flag for it.
fn altDown() bool {
    return w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0;
}

fn xOf(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF))));
}
fn yOf(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF))));
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const self = fromHwnd(hwnd) orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        w32.WM_ERASEBKGND => return 1,
        w32.WM_TIMER => {
            switch (wparam) {
                TIMER_ANIM => self.onMotionTick(),
                TIMER_XFADE => self.onTransitionTick(),
                TIMER_COLUMN => self.onColumnTick(),
                TIMER_REORDER => self.onReorderTick(),
                else => {},
            }
            return 0;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) != 0) self.paintBuffered(hdc, r.right - r.left, r.bottom - r.top, ps.rcPaint);
            return 0;
        },
        w32.WM_NCHITTEST => {
            var pt = w32.POINT{ .x = xOf(lparam), .y = yOf(lparam) };
            _ = w32.ScreenToClient(hwnd, &pt);
            // Up beside the tab strip (T1900) the column only draws: the row
            // is the caption's, so a drag there moves the window and a
            // double-click maximizes it, as on the rest of the band.
            if (pt.y < self.window.paneSidebarReachPx()) return w32.HTTRANSPARENT;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // The same column into a caller's DC, so a pixel probe can photograph
        // it synchronously (the TOC card's T835 reason).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) == 0) return 0;
            self.paint(@ptrFromInt(wparam), r.right - r.left, r.bottom - r.top);
            return 0;
        },
        // The edge's sizer (T1846): over the band, and for the whole drag.
        w32.WM_SETCURSOR => {
            if (self.edge != null) {
                setSizeCursor();
                return 1;
            }
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0 and w32.ScreenToClient(hwnd, &pt) != 0) {
                // The thumb is a thumb, not the sizer under it (T1878).
                if (self.thumb_drag != null or self.thumbAt(pt.x, pt.y) != null) {
                    _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_ARROW));
                    return 1;
                }
                if (self.onEdgeAt(pt.x, pt.y)) {
                    setSizeCursor();
                    return 1;
                }
                // The search field's text takes the text cursor (T1877), and
                // so does a rename field's (T2339).
                if (self.hitAt(pt.x, pt.y) == .search or self.inRenameField(pt.x, pt.y)) {
                    _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_IBEAM));
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CAPTURECHANGED => {
            // Capture taken away mid-drag (another window, a menu): a cancel.
            if (self.item_drag) |d| if (d.settle == null) self.endItemDrag(false);
            self.edgeEnd();
            if (self.thumb_drag != null) {
                self.thumb_drag = null;
                _ = w32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        // The wheel scrolls the list under the pointer (T1878); always
        // consumed, so it never falls through to the parent window's grid.
        w32.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            self.onWheel(delta);
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            if (self.thumb_drag) |d| {
                const l = self.currentLayout();
                self.scrollTo(scroll_mod.dragOffset(&l, y, d.grab, self.scale));
                return 0;
            }
            if (self.edge != null) {
                self.edgeMove(hwnd, x, y);
                return 0;
            }
            // A window or group held: it follows the pointer, and no row
            // under it lights up (T2337, Mac `HoverTrackingView.isHeld`).
            if (self.item_drag) |*d| {
                if (d.settle == null) {
                    d.pointer = y;
                    self.itemRelayout();
                }
                return 0;
            }
            if (self.maybeStartItemDrag(hwnd, x, y)) return 0;
            if (self.maybeStartRowDrag(hwnd, x, y)) return 0;
            // On the edge the pointer means the sizer, not the row under it.
            const on_edge = self.onEdgeAt(x, y);
            self.setHover(if (on_edge) .none else self.hitAt(x, y));
            self.setEdgeHover(on_edge);
            if (!self.tracking) {
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (w32.TrackMouseEvent(&tme) != 0) self.tracking = true;
            }
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.tracking = false;
            if (w32.GetCapture() != hwnd) self.pressed = .none;
            self.setHover(.none);
            self.setEdgeHover(false);
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            // Activation is on the up over the same target (the standard
            // button affordance), so a press that slides off does nothing.
            self.press_x = xOf(lparam);
            self.press_y = yOf(lparam);
            // The overlay thumb (T1878) takes the press on its own height,
            // ahead of the resize band it overlaps.
            if (self.thumbAt(self.press_x, self.press_y)) |grab| {
                self.thumb_drag = .{ .grab = grab };
                _ = w32.SetCapture(hwnd);
                _ = w32.InvalidateRect(hwnd, null, 0);
                log.info("pane sidebar thumb drag start surface=rail", .{});
                return 0;
            }
            // A rename field (T2339): a press in it puts the caret down; a
            // press anywhere else keeps the name - then does what it does.
            if (self.rename != null) {
                if (self.inRenameField(self.press_x, self.press_y)) {
                    self.renameClick(self.press_x);
                    return 0;
                }
                self.endRename(true, "click");
            }
            if (self.onEdgeAt(self.press_x, self.press_y)) {
                self.edgeBegin(hwnd, self.press_x, self.press_y);
                return 0;
            }
            self.pressed = self.hitAt(self.press_x, self.press_y);
            // Alt is the click's modifier when it is down at the PRESS (a
            // swap the user started holding Alt is a swap even if Alt comes
            // up first).
            self.press_alt = altDown();
            _ = w32.SetCapture(hwnd);
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (self.thumb_drag != null) {
                // Cleared here as well as on CAPTURECHANGED: a press whose
                // SetCapture did not take never gets that message.
                self.thumb_drag = null;
                _ = w32.InvalidateRect(hwnd, null, 0);
                _ = w32.ReleaseCapture();
                return 0;
            }
            if (self.edge != null) {
                // The release lands where the last move did; ending here
                // rather than only on WM_CAPTURECHANGED keeps the log line
                // ahead of anything the release triggers.
                self.edgeMove(hwnd, xOf(lparam), yOf(lparam));
                self.edgeEnd();
                _ = w32.ReleaseCapture();
                return 0;
            }
            if (self.item_drag) |d| {
                // Let go: it lands (ended before the capture goes, so the
                // CAPTURECHANGED that follows is not read as a cancel).
                if (d.settle == null) {
                    self.item_drag.?.pointer = yOf(lparam);
                    self.itemRelayout();
                    self.endItemDrag(true);
                }
                self.pressed = .none;
                _ = w32.ReleaseCapture();
                return 0;
            }
            _ = w32.ReleaseCapture();
            const hit = self.hitAt(xOf(lparam), yOf(lparam));
            const pressed = self.pressed;
            self.pressed = .none;
            _ = w32.InvalidateRect(hwnd, null, 0);
            const alt = self.press_alt or altDown();
            self.press_alt = false;
            if (std.meta.eql(hit, pressed)) {
                // A click in the search field puts the caret where it landed.
                if (hit == .search) self.search.setCaret(self.searchCaretAt(xOf(lparam)));
                self.activate(hit, alt);
            }
            return 0;
        },
        // The search field's keyboard (T1877).
        w32.WM_SETFOCUS => {
            if (self.rename != null) {
                log.info("pane sidebar rename focus=true", .{});
                self.repaint();
            } else if (self.searchShown()) {
                self.search_focus = true;
                log.info("pane sidebar search focus=true", .{});
                self.repaint();
            }
            return 0;
        },
        w32.WM_KILLFOCUS => {
            // Clicking away keeps the name (Mac: the field resigning).
            if (self.rename != null) self.endRename(true, "focus");
            if (self.search_focus) {
                self.search_focus = false;
                log.info("pane sidebar search focus=false", .{});
                self.repaint();
            }
            return 0;
        },
        w32.WM_KEYDOWN => {
            if (self.rename != null) {
                if (self.renameKey(@intCast(wparam & 0xFFFF), wparam, lparam)) return 0;
                return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            if (self.searchShown() and self.searchKey(@intCast(wparam & 0xFFFF), wparam, lparam)) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CHAR => {
            const unit: u16 = @truncate(wparam);
            // Return / Escape / Backspace arrive here too, translated from
            // their key: the key handler already acted on them.
            if (unit < 0x20 or unit == 0x7F) return 0;
            if (self.rename) |*r| {
                if (r.field.insert(&.{unit})) self.repaint();
                return 0;
            }
            if (!self.searchShown()) return 0;
            self.searchEdited(self.search.insert(&.{unit}));
            return 0;
        },
        // The row menu opens on the release, the Windows convention (a
        // shell list's context menu does), over the row under the pointer.
        w32.WM_RBUTTONDOWN => return 0,
        w32.WM_RBUTTONUP => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            switch (self.hitAt(x, y)) {
                .item, .item_button, .item_close => |i| self.openRowMenu(hwnd, i, x, y),
                else => {},
            }
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
