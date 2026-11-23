//! Dark-mode replacement for the light `MessageBoxW` prompts (T80).
//!
//! A small owner-centered dialog in the T50 RenameDialog pattern — dark
//! caption, dark client, system icon, message text, OK/Cancel — but with a
//! *synchronous* API: `show` disables the owner, runs its own nested
//! message loop (exactly what MessageBoxW does internally, which the T48
//! analysis established is WndProc-safe: the thread keeps pumping, so the
//! IME/CTF cascade and the IPC message-only window stay live), and returns
//! the user's choice. That keeps every caller's control flow identical to
//! the MessageBoxW it replaces.
//!
//! Semantics preserved from the MessageBoxW sites:
//!   - `default_cancel` mirrors MB_DEFBUTTON2: initial focus and the Enter
//!     default land on Cancel so an accidental Enter never approves a
//!     destructive action.
//!   - Escape cancels (for `ok_only` it simply dismisses).
//!   - The ✕ close box cancels.

const ConfirmDialog = @This();

const std = @import("std");
const App = @import("App.zig");
const w32 = @import("win32.zig");
const type_ramp = @import("type_ramp.zig");
const utf16_text = @import("utf16_text.zig");
const brush_cache = @import("brush_cache.zig");
const panel_theme = @import("panel_theme.zig");
const system_colors = @import("system_colors.zig");
const release_notes = @import("release_notes.zig");
const whats_new_layout = @import("whats_new_layout.zig");
const WhatsNewNotesView = @import("WhatsNewNotesView.zig");
const open_dialogs = @import("open_dialogs.zig");

pub const log = std.log.scoped(.win32);

// -------------------------------------------------------------------------
// Split modules (T1775)
// -------------------------------------------------------------------------
//
// This file is the dialog: its options, state, entry points (show,
// showStandalone, prompt), the degraded MessageBox text, the modal loop and
// the window procedure. Two planes used to live inline here (T1785):
// confirm_dialog_window.zig builds the window and its controls and runs it
// (`run`, plus the MessageBox fallback it drops to), and
// confirm_dialog_layout.zig is the pure geometry (`layoutFor` and the link
// and labelled-row helpers) with its unit tests. Each is imported back as
// aliases so every call site reads as it always did. The aliases are the
// planes' public surface, listed here in one place.

const confirm_dialog_window = @import("confirm_dialog_window.zig");
pub const Output = confirm_dialog_window.Output;
pub const run = confirm_dialog_window.run;
pub const readEdit = confirm_dialog_window.readEdit;
pub const fallback = confirm_dialog_window.fallback;

const confirm_dialog_layout = @import("confirm_dialog_layout.zig");
pub const Layout = confirm_dialog_layout.Layout;
pub const layoutFor = confirm_dialog_layout.layoutFor;
pub const px = confirm_dialog_layout.px;
pub const linkAnchor = confirm_dialog_layout.linkAnchor;
pub const packLinks = confirm_dialog_layout.packLinks;
pub const linkRowWidth = confirm_dialog_layout.linkRowWidth;
pub const rowsExtent = confirm_dialog_layout.rowsExtent;
pub const rowRects = confirm_dialog_layout.rowRects;
pub const link_gap_dip = confirm_dialog_layout.link_gap_dip;
pub const buttonWidth = confirm_dialog_layout.buttonWidth;
pub const wstr = confirm_dialog_layout.wstr;

// (end of split modules)

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyConfirmDialog");

/// `alt` is the optional THIRD button (`Options.alt_label`) — a second
/// affirmative that is not the primary one. It exists for the remote-close
/// confirmation's **Disconnect** (T1390), where "close the window but keep the
/// sessions" is neither OK nor Cancel.
pub const Result = enum { ok, cancel, alt };
pub const Style = enum { ok_only, ok_cancel };
pub const Icon = enum { none, warning, info };

pub const Options = struct {
    title: [*:0]const u16,
    text: [:0]const u16,
    style: Style = .ok_cancel,
    icon: Icon = .warning,
    /// MB_DEFBUTTON2 parity: focus + Enter default on Cancel.
    default_cancel: bool = true,
    /// Button captions. The affirmative/dismissive semantics (and the
    /// Result values) stay OK/Cancel regardless of the label — callers
    /// like the T69 config-errors dialog relabel them ("Open Config" /
    /// "Ignore") without changing any dialog behavior. Buttons widen to
    /// fit the longer caption.
    ok_label: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("OK"),
    cancel_label: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Cancel"),
    /// When non-null (and `style` is `.ok_cancel`), a THIRD button carrying
    /// this caption, returning `.alt`. It takes the LEADING slot of the button
    /// row — `[alt] [ok] [cancel]`, right-aligned with Cancel last — which is
    /// the Windows convention this dialog already follows for two buttons, and
    /// where a Win32 user looks for the primary action. (Mac puts its default
    /// rightmost; the platforms disagree about the row, not about the answer.)
    alt_label: ?[:0]const u16 = null,
    /// Put the Enter default on the third button instead of OK/Cancel. Mac's
    /// remote close defaults to Disconnect — the non-destructive answer — and
    /// so does this. Ignored when there is no `alt_label`.
    default_alt: bool = false,
    /// When non-null the dialog carries a single-line text field seeded with
    /// this text, below the message — Mac's NSAlert `accessoryView` prompts
    /// (rename a relay device, T176) are the same alert with a field bolted
    /// on, so this is the same dialog rather than a second class.
    ///
    /// Only `prompt` reads the field back; `show` ignores it. A field takes
    /// initial focus (with its text selected) and makes OK the Enter default,
    /// because a prompt's Enter must commit what was typed.
    input: ?[:0]const u16 = null,
    /// Optional checkbox rows between the message and the buttons — Mac's
    /// NSAlert accessory checkboxes (the agent-integration first-run offer,
    /// T870). MUTABLE: on OK the dialog writes each row's final state back
    /// into `checked`; on Cancel the values are left as passed. At most
    /// `max_checks` rows.
    checks: []Check = &.{},
    /// Optional RELEASE-NOTES accessory (T625): a scrolling region showing
    /// what an update changed, between the message and the buttons. Mac hangs
    /// the same view off its mandatory agent-restart alert, so the user
    /// answering "this closes your sessions" can see what the restart buys
    /// them.
    ///
    /// The notes scroll INSIDE a fixed band, so a release with twelve bullets
    /// and one with two produce the same dialog — evidence must never move the
    /// buttons the user is reaching for. Ignored on the app-less paths
    /// (`showStandalone`), which have no theme, no allocator and no update
    /// story.
    notes: ?Notes = null,
    /// Optional row of HYPERLINKS under the message (T714) — Mac's About
    /// panel hangs a linked version row, a linked commit row and its Docs /
    /// GitHub buttons off the same alert-shaped surface, and the win32 About
    /// box had no clickable anything: a block of provenance text with no way
    /// from the app to the release it is running.
    ///
    /// BORROWED, like `notes`: `show` does not return until the dialog is
    /// gone, so the caller's arena is exactly right. At most `max_links`.
    /// Ignored on the app-less paths (`showStandalone`) — opening a URL needs
    /// an `App`, and a link that does nothing is worse than no link.
    links: []const Link = &.{},
    /// Optional LABELLED ROWS under the message (T1556) - Mac's About panel
    /// `PropertyRow`s: a right-aligned label column and a left-aligned value
    /// column, each value selectable so a commit or a path can be copied. The
    /// About box used to print the same facts as one preformatted block, which
    /// read as a diagnostic dump. BORROWED like `links`. At most `max_rows`;
    /// a value wider than `max_row_value_dip` scrolls inside its cell rather
    /// than widening the dialog off the screen.
    rows: []const Row = &.{},
    /// Optional caption-sized secondary note under the check rows — Mac's
    /// wrapping caption label in the first-launch accessory (T600, the
    /// agent-config-write disclosure). Rendered in the caption ramp role and
    /// the secondary text color, so it reads as fine print rather than a
    /// second message paragraph.
    note: ?[:0]const u16 = null,
    /// When non-null, the dialog dismisses ITSELF after this many ms and
    /// returns `.cancel` — the dismissive answer, never an approval, and on
    /// an `.ok_only` box the one result no user action produces, so the
    /// caller can tell a timeout from a read (T2321). For the app-less
    /// reporters whose process must not outlive its message: the update
    /// applier sat on an unseen modal for 26 hours and held its own image
    /// locked against every later update. Not honoured by `fallback`, which
    /// is reached only when the class could not even register.
    timeout_ms: ?u32 = null,
};

pub const Notes = struct {
    /// The split to show. BORROWED — the caller owns the store these slices
    /// point into, and `show` does not return until the dialog is gone, so a
    /// stack-owned store is exactly right.
    split: release_notes.Partitioned,
};

pub const Check = struct {
    label: [:0]const u16,
    checked: bool = true,
};

/// One hyperlink in the optional link row (T714). `url` is handed to
/// `App.openUrl` verbatim when the anchor is activated.
pub const Link = struct {
    label: []const u16,
    url: []const u8,
};

/// One labelled row (`Options.rows`, T1556).
pub const Row = struct {
    label: [:0]const u16,
    value: [:0]const u16,
};

/// Labelled-row capacity - the About box's eight.
pub const max_rows = 8;

/// The widest a row's value cell grows before it scrolls instead (DIPs).
pub const max_row_value_dip: f32 = 520;

/// Gap between the label column and the value column, between two rows, and
/// between the message and the first row (DIPs).
pub const row_col_gap_dip: f32 = 8;
pub const row_gap_dip: f32 = 4;
pub const rows_gap_dip: f32 = 12;

/// Checkbox row capacity (two agent runtimes today; room to grow).
pub const max_checks = 4;

/// Link row capacity — About's four (release, commit, docs, repo).
pub const max_links = 4;

/// Control ids for the link row. One SysLink control PER link, rather than one
/// control carrying four anchors: a control is a Tab stop, so one-per-link is
/// what makes every link reachable from the keyboard through this dialog's own
/// focus cycle. A single multi-anchor control would put its first anchor in
/// the cycle and leave the rest reachable only by mouse.
pub const ID_LINK_BASE: u16 = 300;

/// Control id for the optional third button (T1390). A private value: the
/// checkbox rows own 100.., and IDOK/IDCANCEL are already spoken for.
pub const ID_ALT: u16 = 200;

/// Timer id for `Options.timeout_ms`.
pub const TIMEOUT_TIMER_ID: usize = 1;

/// The dialog's palette (T563), derived from the surface `window-theme` puts
/// the app on and the accent the user picked — the derivation the panels got
/// in T308. It was four literals described as "the RenameDialog dark palette",
/// which is a fine description of a dialog that can only ever be dark and a
/// defect on a light system theme.
///
/// `app` is optional because this dialog has an app-less path: the
/// startup-failure box (T1177) runs before there is an `App`, and the
/// standalone updater has none at all. With no configured `window-theme` and
/// no configured background to derive from, the honest surface is the OS apps
/// theme — which is what any other app-less Windows dialog follows.
pub fn pal(self: *const ConfirmDialog) panel_theme.Panel {
    return if (self.app) |a| system_colors.panelFor(a) else system_colors.panelSystem();
}

/// Keyed on the color they were made for: a GDI brush is immutable, so a theme
/// flip has to mean a new object rather than a handle stuck on the old palette.
var class_registered: bool = false;

/// Every dialog whose modal loop is running right now, innermost on top
/// (T2938). GUI thread only, like the dialogs themselves.
pub var open_stack: open_dialogs.Stack = .{};

fn rootOf(owner: usize) usize {
    const h: w32.HWND = @ptrFromInt(owner);
    const root = w32.GetAncestor(h, w32.GA_ROOT) orelse return owner;
    return @intFromPtr(root);
}

/// How many dialogs are open over the top-level window `window` - the win32
/// `attachedSheet` (T2938). A `+close` of that window, or of a pane in it,
/// would be closing it out from under a question the user has not answered.
pub fn openOver(window: w32.HWND) usize {
    return open_stack.countOver(@intFromPtr(window), rootOf);
}

/// Answer every dialog open over `window` with its dismissive result (Cancel,
/// or OK for an OK-only notice) - `+close --force`. Each modal loop sees the
/// answer and unwinds when control returns to it, so the caller must not tear
/// the window down until then (see `App.forceCloseDeferred`). Returns how many.
pub fn dismissOver(window: w32.HWND) usize {
    return open_stack.dismissOver(@intFromPtr(window), rootOf);
}

pub fn dismissFromRegistry(ctx: *anyopaque) void {
    const self: *ConfirmDialog = @ptrCast(@alignCast(ctx));
    // The Escape answer: Cancel, or "ok" for an OK-only notice (MB_OK parity).
    self.finish(if (self.cancel_btn == null) .ok else .cancel);
}
var bg_brush: brush_cache.CachedBrush = .{};
var field_brush: brush_cache.CachedBrush = .{};

/// The app whose theme this dialog paints from, or null on the app-less
/// paths (`showStandalone`, and the updater's own process).
app: ?*App,
hwnd: w32.HWND,
static: ?w32.HWND,
/// The optional secondary note (`Options.note`), colored separately in
/// WM_CTLCOLORSTATIC.
note_static: ?w32.HWND = null,
ok_btn: w32.HWND,
cancel_btn: ?w32.HWND,
/// The optional third button (`Options.alt_label`), returning `.alt` (T1390).
alt_btn: ?w32.HWND = null,
/// The optional text field (`Options.input`), read back by `prompt`.
edit: ?w32.HWND = null,
/// The optional release-notes accessory (`Options.notes`), T625. Owns its own
/// scroll offset and swallows the wheel while the pointer is over it.
notes_view: ?*WhatsNewNotesView = null,
/// The optional checkbox rows (`Options.checks`), read back on OK.
check_btns: [max_checks]?w32.HWND = @splat(null),
n_checks: usize = 0,
/// The optional link row (`Options.links`), T714 — one SysLink per link,
/// indexed like `links`.
link_ctls: [max_links]?w32.HWND = @splat(null),
/// What those controls point at. Borrowed from the caller's `Options` for the
/// life of the modal loop (which is the life of this struct).
links: []const Link = &.{},
/// The optional labelled rows (`Options.rows`), T1556: a right-aligned label
/// STATIC and a read-only, selectable value EDIT per row, indexed like `rows`.
row_labels: [max_rows]?w32.HWND = @splat(null),
row_values: [max_rows]?w32.HWND = @splat(null),
n_rows: usize = 0,
icon_handle: ?w32.HICON,
icon_rect: w32.RECT,
default_cancel: bool,
/// Enter (and initial focus) lands on the third button rather than OK/Cancel.
/// Mutually exclusive with `default_cancel`, which `run` resolves.
default_alt: bool = false,
result: Result = .cancel,
done: bool = false,


/// Show the dialog modally and return the user's choice. `owner` is
/// disabled for the duration (input-modal to that window; the app loop
/// keeps effectively running because we pump here). `refocus`, when given,
/// receives deferred focus after the dialog closes (T48 pattern) — pass
/// the active terminal surface HWND, or null when the window is about to
/// be destroyed anyway (posted focus to a dead HWND is dropped by the OS).
pub fn show(
    app: *App,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    opts: Options,
) Result {
    return run(app, app.hinstance, owner, scale, refocus, opts, null);
}

/// The same dialog with NO App behind it — the startup-failure path (T1177),
/// which runs when `App.create` or the runtime's `init` failed and there is
/// therefore no app, no window and no message loop to borrow. The dialog only
/// ever needed the app for its window-class instance handle, so that is all
/// this asks for; `null` resolves the process instance, which is what every
/// other class registration in this app uses.
pub fn showStandalone(owner: ?w32.HWND, scale: f32, opts: Options) Result {
    const hinstance = w32.GetModuleHandleW(null);
    return run(null, hinstance, owner, scale, null, opts, null);
}

/// The scale an app-less dialog should be drawn at: the PRIMARY monitor's, in
/// the units `scale` is everywhere else (1.0 == 96 DPI).
///
/// A dialog with an owner takes its scale from that window, which is how every
/// in-app prompt follows the monitor it is on. An app-less one has no window to
/// ask and centers on the primary screen (see `run`'s SM_CXSCREEN fallback), so
/// the primary monitor's DPI is the right — and only — answer. Passing a flat
/// 1.0 instead draws a 96-DPI dialog in a per-monitor-aware process, which on a
/// 150% display is a warning two thirds the size of every other prompt.
pub fn standaloneScale() f32 {
    const dpi = w32.GetDpiForSystem();
    if (dpi == 0) return 1.0;
    return @as(f32, @floatFromInt(dpi)) / 96.0;
}

/// Show a dialog carrying a text field (`opts.input` MUST be set) and return
/// what the user left in it, UTF-8 in `buf`, or null when they cancelled —
/// the win32 counterpart to Mac's NSAlert-with-accessoryView prompts.
///
/// Whitespace and no-op handling belong to the caller (see
/// `chooser_menu.newName`): this returns the field verbatim.
pub fn prompt(
    app: *App,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    opts: Options,
    buf: []u8,
) ?[]const u8 {
    std.debug.assert(opts.input != null);
    var out: Output = .{ .buf = buf };
    if (run(app, app.hinstance, owner, scale, refocus, opts, &out) != .ok) return null;
    return buf[0..out.len];
}


/// The text the degraded system box shows: the message, then the labelled
/// rows as `Label: value` lines (T1556), then the note. Pure - unit tested
/// below. Null when the whole of it cannot fit `out`; the caller then ships
/// the message alone.
///
/// The note is a disclosure, not decoration (T600) - a fallback that dropped
/// it would show a consent prompt missing its fine print. The rows are the
/// About box's whole content; a fallback About that dropped them would say
/// "Ghoztty" and nothing about which build.
pub fn fallbackText(out: []u16, text: []const u16, rows: []const Row, note: ?[]const u16) ?[:0]const u16 {
    var n: usize = 0;
    const put = struct {
        fn put(o: []u16, i: *usize, part: []const u16) bool {
            if (i.* + part.len >= o.len) return false;
            @memcpy(o[i.*..][0..part.len], part);
            i.* += part.len;
            return true;
        }
    }.put;
    const nl2 = std.unicode.utf8ToUtf16LeStringLiteral("\n\n");
    const nl = std.unicode.utf8ToUtf16LeStringLiteral("\n");
    const sep = std.unicode.utf8ToUtf16LeStringLiteral(": ");
    if (!put(out, &n, text)) return null;
    for (rows[0..@min(rows.len, max_rows)], 0..) |row, i| {
        if (!put(out, &n, if (i == 0) nl2 else nl)) return null;
        if (!put(out, &n, row.label)) return null;
        if (!put(out, &n, sep)) return null;
        if (!put(out, &n, row.value)) return null;
    }
    if (note) |t| {
        if (!put(out, &n, nl2)) return null;
        if (!put(out, &n, t)) return null;
    }
    out[n] = 0;
    return out[0..n :0];
}

/// Nested modal message pump — the same shape MessageBoxW runs internally.
/// Replicates the App.run top-of-loop specials that matter while modal:
/// WM_APP_SETFOCUS (T48 deferred focus) is performed here, never
/// dispatched. Everything else (renderer wakeups, IPC — both handled in
/// window procs) flows through Translate/Dispatch as usual.
pub fn runModal(self: *ConfirmDialog) void {
    var msg: w32.MSG = undefined;
    while (!self.done) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT: repost for the outer App.run loop and bail out
            // without approving anything.
            w32.PostQuitMessage(@intCast(msg.wParam));
            self.result = .cancel;
            return;
        }
        if (result < 0) {
            self.result = .cancel;
            return;
        }
        if (msg.message == App.WM_APP_SETFOCUS) {
            if (msg.hwnd) |h| App.performDeferredFocus(h);
            continue;
        }
        // The wheel goes to the FOCUSED window, which in this dialog is a
        // button — and a BUTTON does not forward it to its parent. So the
        // notes accessory would never see a scroll it plainly invites, unless
        // the loop that owns the dialog routes by POINTER instead, which is
        // what every scrolling region on Windows behaves like anyway.
        if (msg.message == w32.WM_MOUSEWHEEL) {
            if (self.notes_view) |v| {
                const pt: w32.POINT = .{
                    .x = @as(i16, @bitCast(@as(u16, @intCast(msg.lParam & 0xFFFF)))),
                    .y = @as(i16, @bitCast(@as(u16, @intCast((msg.lParam >> 16) & 0xFFFF)))),
                };
                var rc: w32.RECT = undefined;
                if (w32.GetWindowRect(v.hwnd, &rc) != 0 and
                    pt.x >= rc.left and pt.x < rc.right and
                    pt.y >= rc.top and pt.y < rc.bottom)
                {
                    _ = w32.SendMessageW(v.hwnd, msg.message, msg.wParam, msg.lParam);
                    continue;
                }
            }
        }
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null and self.ownsHwnd(msg.hwnd.?)) {
            const vk: u16 = @intCast(msg.wParam & 0xFFFF);
            if (self.handleKey(vk)) continue;
        }
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

/// What Enter answers when focus is not on a button. Pure, and the one place
/// the two default flags are resolved into an answer.
pub fn defaultResultFor(default_alt: bool, default_cancel: bool) Result {
    if (default_alt) return .alt;
    if (default_cancel) return .cancel;
    return .ok;
}

fn defaultResult(self: *const ConfirmDialog) Result {
    return defaultResultFor(self.default_alt and self.alt_btn != null, self.default_cancel);
}

pub fn defaultButton(self: *const ConfirmDialog) w32.HWND {
    // The third button wins when it asked for the default (T1390): the
    // remote-close confirmation defaults to Disconnect, the answer that
    // destroys nothing.
    if (self.default_alt) {
        if (self.alt_btn) |a| return a;
    }
    if (self.default_cancel) {
        if (self.cancel_btn) |c| return c;
    }
    return self.ok_btn;
}

/// The dialog's own owner-drawn content, into whichever DC it is handed — the
/// paint cycle's own, or a caller's under WM_PRINTCLIENT (T940).
fn paintInto(self: *const ConfirmDialog, hdc: w32.HDC) void {
    if (self.icon_handle) |icon| {
        _ = w32.DrawIconEx(
            hdc,
            self.icon_rect.left,
            self.icon_rect.top,
            icon,
            self.icon_rect.right - self.icon_rect.left,
            self.icon_rect.bottom - self.icon_rect.top,
            0,
            null,
            w32.DI_NORMAL,
        );
    }
}

fn isRowValue(self: *const ConfirmDialog, ctl: ?w32.HWND) bool {
    const c = ctl orelse return false;
    for (self.row_values[0..self.n_rows]) |maybe| if (maybe) |v| {
        if (c == v) return true;
    };
    return false;
}

fn ownsHwnd(self: *const ConfirmDialog, hwnd: w32.HWND) bool {
    if (hwnd == self.hwnd or hwnd == self.ok_btn) return true;
    if (self.static) |s| if (hwnd == s) return true;
    if (self.note_static) |s| if (hwnd == s) return true;
    // A clicked row value takes focus; Escape and Enter must still answer.
    for (self.row_values[0..self.n_rows]) |maybe| if (maybe) |v| {
        if (hwnd == v) return true;
    };
    for (self.link_ctls[0..self.links.len]) |maybe| if (maybe) |lc| {
        if (hwnd == lc) return true;
    };
    if (self.cancel_btn) |c| if (hwnd == c) return true;
    if (self.alt_btn) |a| if (hwnd == a) return true;
    if (self.edit) |e| if (hwnd == e) return true;
    for (self.check_btns[0..self.n_checks]) |maybe| if (maybe) |b| {
        if (hwnd == b) return true;
    };
    return false;
}

/// Tab order: field (when present) → OK → Cancel → wrap. Pure — unit-tested
/// through `nextFocusIndex`, which is the same cycle over stop indices.
pub fn nextFocusIndex(cur: usize, stops: usize, backwards: bool) usize {
    if (stops == 0) return 0;
    if (backwards) return (cur + stops - 1) % stops;
    return (cur + 1) % stops;
}

/// Which link a control id names, or null when it names something else. Pure —
/// the id space is `ID_LINK_BASE ..< ID_LINK_BASE + max_links`, chosen to miss
/// IDOK/IDCANCEL, the checkbox rows at 100.. and `ID_ALT` at 200.
pub fn linkIndexFor(id: usize, n_links: usize) ?usize {
    if (id < ID_LINK_BASE) return null;
    const i = id - ID_LINK_BASE;
    if (i >= n_links) return null;
    return i;
}

/// Follow an activated link. The dialog stays open: About is where the user
/// looks things up, and closing it to answer "what is this build?" would take
/// away the answer they were reading.
fn openLink(self: *ConfirmDialog, id: usize) void {
    const i = linkIndexFor(id, self.links.len) orelse return;
    const app = self.app orelse return;
    app.openUrl(self.links[i].url);
}

fn finish(self: *ConfirmDialog, result: Result) void {
    self.result = result;
    self.done = true;
}

/// Handle a dialog key from the nested pump. Returns true when consumed.
fn handleKey(self: *ConfirmDialog, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            // MB_OK parity: Escape dismisses an OK-only box as "ok".
            self.finish(if (self.cancel_btn == null) .ok else .cancel);
            return true;
        },
        w32.VK_RETURN => {
            // Enter activates the focused button, else the default —
            // standard dialog convention (MB_DEFBUTTON2 preserved). Enter in
            // the text field commits, like any prompt.
            const focus = w32.GetFocus();
            // ...but Enter on a focused LINK follows the link (T714). The
            // control turns it into NM_RETURN, so this must not consume it —
            // otherwise the one key a keyboard user would reach for to open
            // the link dismisses the dialog instead.
            if (focus) |f| {
                for (self.link_ctls[0..self.links.len]) |maybe| if (maybe) |lc| {
                    if (f == lc) return false;
                };
            }
            if (self.cancel_btn != null and focus == self.cancel_btn) {
                self.finish(.cancel);
            } else if (self.alt_btn != null and focus == self.alt_btn) {
                self.finish(.alt);
            } else if (focus == @as(?w32.HWND, self.ok_btn)) {
                self.finish(.ok);
            } else {
                self.finish(self.defaultResult());
            }
            return true;
        },
        w32.VK_TAB => {
            // Focus stops in order: checkboxes (top-down), the link row
            // (left to right, T714), field (when present), then the button row
            // LEFT TO RIGHT as it is painted — the third button, OK, Cancel
            // (T1390).
            var stops: [4 + max_checks + max_links]w32.HWND = undefined;
            var n: usize = 0;
            for (self.check_btns[0..self.n_checks]) |maybe| if (maybe) |b| {
                stops[n] = b;
                n += 1;
            };
            for (self.link_ctls[0..self.links.len]) |maybe| if (maybe) |lc| {
                stops[n] = lc;
                n += 1;
            };
            if (self.edit) |e| {
                stops[n] = e;
                n += 1;
            }
            if (self.alt_btn) |a| {
                stops[n] = a;
                n += 1;
            }
            stops[n] = self.ok_btn;
            n += 1;
            if (self.cancel_btn) |c| {
                stops[n] = c;
                n += 1;
            }
            if (n < 2) return true;

            const focus = w32.GetFocus();
            var cur: usize = 0;
            for (stops[0..n], 0..) |h, i| {
                if (focus == @as(?w32.HWND, h)) cur = i;
            }
            const backwards = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            _ = w32.SetFocus(stops[nextFocusIndex(cur, n, backwards)]);
            return true;
        },
        else => return false,
    }
}

pub fn registerClass(hinstance: ?w32.HINSTANCE) ?void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &dialogWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        // Null, erased from the live palette in `WM_ERASEBKGND` instead
        // (T563) - a class brush is captured once per process, so it cannot
        // follow a theme flip.
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("confirm dialog class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *ConfirmDialog = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (notification == w32.BN_CLICKED) {
                switch (control_id) {
                    @as(u16, @intCast(w32.IDOK)) => {
                        self.finish(.ok);
                        return 0;
                    },
                    @as(u16, @intCast(w32.IDCANCEL)) => {
                        self.finish(.cancel);
                        return 0;
                    },
                    ID_ALT => {
                        self.finish(.alt);
                        return 0;
                    },
                    else => {},
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // The link row (T714). SysLink reports an activated anchor here for
        // BOTH mouse and keyboard, and asks for its text color here too.
        w32.WM_NOTIFY => {
            const nm: *const w32.NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            switch (nm.code) {
                w32.NM_CLICK, w32.NM_RETURN => {
                    self.openLink(nm.idFrom);
                    return 0;
                },
                w32.NM_CUSTOMDRAW => {
                    const cd: *const w32.NMCUSTOMDRAW_HEAD =
                        @ptrFromInt(@as(usize, @bitCast(lparam)));
                    // A SysLink draws its anchors in COLOR_HOTLIGHT, a fixed
                    // system blue that does not follow the app theme — on this
                    // dialog's dark surface it is a link you have to hunt for.
                    // The panel's accent is the color every other link in this
                    // app uses (see `whats_new_notes.zig`) and it carries a
                    // 3:1 floor against the surface it is drawn on.
                    if (cd.dwDrawStage == w32.CDDS_PREPAINT) return w32.CDRF_NOTIFYITEMDRAW;
                    if (cd.dwDrawStage == w32.CDDS_ITEMPREPAINT) {
                        _ = w32.SetTextColor(cd.hdc, system_colors.cr(self.pal().accent));
                        return w32.CDRF_NEWFONT;
                    }
                    return w32.CDRF_DODEFAULT;
                },
                else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
            }
        },
        w32.WM_TIMER => {
            if (wparam != TIMEOUT_TIMER_ID) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            _ = w32.KillTimer(hwnd, TIMEOUT_TIMER_ID);
            self.finish(.cancel);
            return 0;
        },
        w32.WM_CLOSE => {
            // ✕ dismisses: cancel for confirms, ok for OK-only boxes.
            self.finish(if (self.cancel_btn == null) .ok else .cancel);
            return 0;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.paintInto(hdc);
            return 0;
        },
        // The same icon into a caller's DC, so a pixel probe can photograph
        // this dialog synchronously instead of through DWM's asynchronous copy
        // of the composited surface, which tears (T835/T940). The dialog's
        // TEXT is in child statics, which DefWindowProc's WM_PRINT handling
        // prints for us; only the owner-drawn icon comes from here.
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            self.paintInto(@ptrFromInt(wparam));
            return 0;
        },
        w32.WM_ACTIVATE => {
            // Restore focus to the default button when reactivated (e.g.
            // after alt-tabbing away) and no child holds it.
            const state: u16 = @intCast(wparam & 0xFFFF);
            if (state != w32.WA_INACTIVE) {
                const focus = w32.GetFocus();
                const owned = focus != null and self.ownsHwnd(focus.?);
                if (!owned) _ = w32.SetFocus(self.edit orelse self.defaultButton());
            }
            return 0;
        },
        // The class carries no background brush (it would be frozen at
        // registration time), so the dialog surface is erased here from the
        // live palette instead.
        w32.WM_ERASEBKGND => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            var er: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &er) == 0) return 0;
            if (bg_brush.get(system_colors.cr(self.pal().bg))) |b| _ = w32.FillRect(hdc, &er, b);
            return 1;
        },
        // A light/dark flip or an accent change reaches TOP-LEVEL windows, and
        // this dialog is one. Repaint it AND its children: a control colors
        // itself from a `WM_CTLCOLOR*` reply, which is only sent when it
        // repaints (T307).
        w32.WM_SETTINGCHANGE, w32.WM_DWMCOLORIZATIONCOLORCHANGED => {
            if (msg != w32.WM_SETTINGCHANGE or system_colors.isColorSettingChange(lparam)) {
                // The frame and the common controls were themed once, at creation;
                // a light/dark flip has to move them with the surface (T1374).
                system_colors.applyPanelChrome(hwnd, self.pal());
                system_colors.rethemeControls(hwnd, self.pal());
                system_colors.repaintForColorChange(hwnd);
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // The prompt field is a field, not dialog surface — without this it
        // renders as a white box in an otherwise dark dialog.
        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const p = self.pal();
            _ = w32.SetTextColor(hdc, system_colors.cr(p.text));
            _ = w32.SetBkColor(hdc, system_colors.cr(p.field));
            if (field_brush.get(system_colors.cr(p.field))) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const p = self.pal();
            // lparam names the control: the note reads in the secondary
            // ramp, everything else in the message color.
            const ctl: ?w32.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const color = if (self.note_static != null and ctl == self.note_static)
                p.secondary
            else if (self.isRowValue(ctl))
                // Mac's PropertyRow: the label in the body color, the value
                // dimmed beside it (T1556).
                p.secondary
            else
                p.text;
            _ = w32.SetTextColor(hdc, system_colors.cr(color));
            _ = w32.SetBkColor(hdc, system_colors.cr(p.bg));
            if (bg_brush.get(system_colors.cr(p.bg))) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------
// Tests (pure logic only — run in both test lanes)
// ---------------------------------------------------------------------

pub const testing = std.testing;

test "defaultResultFor: the third button outranks OK and Cancel" {
    // The remote close defaults to Disconnect - the answer that destroys
    // nothing - so Enter on an untouched dialog must not end a remote process.
    try testing.expectEqual(Result.alt, defaultResultFor(true, true));
    try testing.expectEqual(Result.alt, defaultResultFor(true, false));
    try testing.expectEqual(Result.cancel, defaultResultFor(false, true));
    try testing.expectEqual(Result.ok, defaultResultFor(false, false));
}

test "nextFocusIndex: cycles both ways and wraps" {
    // field -> OK -> Cancel -> field
    try testing.expectEqual(@as(usize, 1), nextFocusIndex(0, 3, false));
    try testing.expectEqual(@as(usize, 2), nextFocusIndex(1, 3, false));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(2, 3, false));
    try testing.expectEqual(@as(usize, 2), nextFocusIndex(0, 3, true));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(1, 3, true));
    // Two stops (no field) is the old OK <-> Cancel toggle.
    try testing.expectEqual(@as(usize, 1), nextFocusIndex(0, 2, false));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(1, 2, false));
    try testing.expectEqual(@as(usize, 1), nextFocusIndex(0, 2, true));
    // Degenerate cases never index out of range.
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(0, 1, false));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(0, 0, false));
}

test "linkIndexFor: the link id space misses every other control's" {
    try testing.expectEqual(@as(?usize, 0), linkIndexFor(ID_LINK_BASE, 4));
    try testing.expectEqual(@as(?usize, 3), linkIndexFor(ID_LINK_BASE + 3, 4));
    // Out of the row: a build with two links must not answer for a fourth id.
    try testing.expectEqual(@as(?usize, null), linkIndexFor(ID_LINK_BASE + 2, 2));
    try testing.expectEqual(@as(?usize, null), linkIndexFor(ID_LINK_BASE + max_links, max_links));
    // The ids every other control in this dialog owns.
    try testing.expectEqual(@as(?usize, null), linkIndexFor(@intCast(w32.IDOK), 4));
    try testing.expectEqual(@as(?usize, null), linkIndexFor(@intCast(w32.IDCANCEL), 4));
    try testing.expectEqual(@as(?usize, null), linkIndexFor(ID_ALT, 4));
    try testing.expectEqual(@as(?usize, null), linkIndexFor(100, 4));
    try testing.expectEqual(@as(?usize, null), linkIndexFor(100 + max_checks - 1, 4));
}

test "fallbackText: the rows ride along as Label: value lines (T1556)" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [256]u16 = undefined;
    const rows = [_]Row{
        .{ .label = L("Version"), .value = L("Tip Release") },
        .{ .label = L("Commit"), .value = L("8bf37b334") },
    };
    const got = fallbackText(&buf, L("Ghoztty"), &rows, L("fine print")).?;
    try testing.expectEqualSlices(u16, L("Ghoztty\n\nVersion: Tip Release\nCommit: 8bf37b334\n\nfine print"), got);
}

test "fallbackText: no rows and no note is the message unchanged (T1556)" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [64]u16 = undefined;
    try testing.expectEqualSlices(u16, L("hello"), fallbackText(&buf, L("hello"), &.{}, null).?);
}

test "fallbackText: too long for the buffer is null, never truncated (T1556)" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [8]u16 = undefined;
    try testing.expect(fallbackText(&buf, L("hello"), &.{}, L("note")) == null);
    try testing.expect(fallbackText(&buf, L("12345678"), &.{}, null) == null);
}

test "every app-less dialog is drawn at the display's scale, never a literal (T1558)" {
    // `showStandalone` has no owner window to inherit a DPI from, so its caller
    // supplies the scale. A literal there (it was `1.0` at five sites until
    // T1558) draws a 96-DPI dialog in a PerMonitorV2 process: on a 150% display
    // it comes up two thirds the size of every in-app prompt. Every caller is
    // listed here; one that stops calling `showStandalone` fails too, so the
    // list cannot quietly go stale.
    const callers = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "startup_error.zig", .src = @embedFile("startup_error.zig") },
        .{ .name = "install_restart.zig", .src = @embedFile("install_restart.zig") },
        .{ .name = "install_maintenance.zig", .src = @embedFile("install_maintenance.zig") },
        .{ .name = "update_install.zig", .src = @embedFile("update_install.zig") },
        .{ .name = "url_scheme.zig", .src = @embedFile("url_scheme.zig") },
    };
    const needle = "ConfirmDialog.showStandalone(";
    for (callers) |c| {
        var calls: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, c.src, at, needle)) |i| {
            at = i + needle.len;
            calls += 1;
            // Second argument: the text between the first and second comma.
            const first = std.mem.indexOfScalarPos(u8, c.src, at, ',') orelse return error.TestUnexpectedResult;
            const second = std.mem.indexOfScalarPos(u8, c.src, first + 1, ',') orelse return error.TestUnexpectedResult;
            const arg = std.mem.trim(u8, c.src[first + 1 .. second], " \t\r\n");
            if (arg.len == 0 or std.ascii.isDigit(arg[0])) {
                std.debug.print("{s}: showStandalone scale is the literal '{s}'; use ConfirmDialog.standaloneScale()\n", .{ c.name, arg });
                return error.TestUnexpectedResult;
            }
        }
        if (calls == 0) {
            std.debug.print("{s} no longer calls showStandalone; drop it from this list\n", .{c.name});
            return error.TestUnexpectedResult;
        }
    }
}
