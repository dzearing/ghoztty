const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const TitlebarStyle = configpkg.Config.GtkTitlebarStyle;
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gtk_version = @import("../gtk_version.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const winprotopkg = @import("../winproto.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const disconnect_offer = @import("../disconnect_offer.zig");
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const CloseUndo = @import("../CloseUndo.zig");
const RelayWindows = @import("../RelayWindows.zig");
const PaneSidebar = @import("../PaneSidebar.zig");
const PaneDrag = @import("../PaneDrag.zig");
const pane_drop = @import("../../win32/pane_drop.zig");
const pane_drop_apply = @import("../pane_drop_apply.zig");
const wk = @import("../webkit.zig");
const window_activity = @import("../window_activity.zig");
const window_seen = @import("../window_seen.zig");
const activity_attention = @import("../../win32/activity_attention.zig");
const pane_style = @import("../pane_style.zig");
const color_math = @import("../../win32/color_math.zig");
const RemoteLink = @import("../RemoteLink.zig");
const Workspaces = @import("../Workspaces.zig");
const desk_fade = @import("../../win32/desk_fade.zig");

const log = std.log.scoped(.gtk_ghostty_window);

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;

    /// The qdata key a workspace's content root carries, naming the `Window`
    /// it belongs to (T3648). `ext.getAncestor(Window, ...)` reads it before
    /// the widget tree, so in single-window mode a pane answers the
    /// workspace it is in - on show in the shared toplevel, or parked out of
    /// every window - and never the toplevel's own workspace (Mac
    /// `BaseTerminalController.owner(of:)`).
    pub const workspace_qdata_key: [:0]const u8 = "ghoztty-workspace";

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the focus that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Self) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };

        pub const @"titlebar-style" = struct {
            pub const name = "titlebar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                TitlebarStyle,
                .{
                    .default = .native,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        TitlebarStyle,
                        .{
                            .getter = Self.getTitlebarStyle,
                        },
                    ),
                },
            );
        };

        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };

        pub const @"quick-terminal" = struct {
            pub const name = "quick-terminal";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "quick_terminal",
                    ),
                },
            );
        };

        pub const @"tabs-autohide" = struct {
            pub const name = "tabs-autohide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsAutohide,
                    }),
                },
            );
        };

        pub const @"tabs-wide" = struct {
            pub const name = "tabs-wide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsWide,
                    }),
                },
            );
        };

        pub const @"tabs-visible" = struct {
            pub const name = "tabs-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsVisible,
                    }),
                },
            );
        };

        pub const @"toolbar-style" = struct {
            pub const name = "toolbar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                adw.ToolbarStyle,
                .{
                    .default = .raised,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        adw.ToolbarStyle,
                        .{
                            .getter = Self.getToolbarStyle,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// Whether this window is a quick terminal. If it is then it
        /// behaves slightly differently under certain scenarios.
        quick_terminal: bool = false,

        /// The window decoration override. If this is not set then we'll
        /// inherit whatever the config has. This allows overriding the
        /// config on a per-window basis.
        window_decoration: ?configpkg.WindowDecoration = null,

        /// The window's IPC name (`+new-window --target`, else a minted
        /// `window-N`; T3370). Window names are global. Owned.
        ipc_name: ?[]u8 = null,

        /// A title pinned by `+rename` / `+new-window --title` (T3370): while
        /// set it wins over the active tab's title, as the Mac's
        /// `titleOverride` does. Owned.
        title_override: ?[:0]u8 = null,

        /// Whether the window can be seen (T3571, `window_seen.windowSeen`)
        /// as last computed: mapped, not minimized, not suspended.
        seen: bool = true,

        /// A Debug-only stand-in for the compositor's toplevel state (the
        /// `pane-seen` seam): the headless Weston the Linux tests run in
        /// never minimizes or suspends a window.
        toplevel_override: ?window_seen.Toplevel = null,

        /// Single-window mode (T3648): this workspace's content root while
        /// it is out of every window (parked), held by this reference.
        held_content: ?*gtk.Widget = null,

        /// Single-window mode (T3652): this window's own workspace has
        /// closed, but its GtkWindow is the shared toplevel and stays on as
        /// the FRAME the other workspaces are shown in (Mac: the NSWindow
        /// outlives the controller that loaded it). It has no tabs, no
        /// sidebar and no name; nothing lists it; it goes with the last
        /// workspace.
        frame_only: bool = false,

        /// A title composed while the window was hidden and not yet set on
        /// it (T3571): it lands when the window shows, or when
        /// `held_title_timer` fires. Owned.
        held_title: ?[:0]u8 = null,
        held_title_timer: c_uint = 0,

        /// When a title was last set on the window (monotonic ms), or null
        /// before the first: a hidden window's first title always lands.
        title_landed_ms: ?i64 = null,

        /// This window's last-seen activity aggregate, reduced to whether it
        /// waits on a question (T3654, win32 T2907): a move INTO
        /// `needs_input` asks for attention once. Moves while parked too.
        activity_attention: activity_attention.Tracker = .{},

        /// The pane sidebar (T3557): the column before the tabs that lists
        /// the active tab's panes. Owned; its widgets belong to the tree.
        pane_sidebar: ?*PaneSidebar = null,

        /// Pane rearrange mode (T3564): every pane shows its drag header
        /// and the tab bar is forced visible. Per window, like the Mac's.
        rearrange_mode: bool = false,

        /// The tab-bar dwell of a pane drag (T3615): the tab a drag is
        /// resting on and the 500ms clock that selects it.
        dwell_tab: ?usize = null,
        dwell_timer: ?c_uint = null,

        /// The window's own gradient desk in the elevated pane style
        /// (T3566; Mac `PaneDeskVariant`): null is the shared ocean.
        /// Decided on first use - a hand-opened window follows
        /// `macos-window-gradient` - unless `+new-window --color` set it
        /// first (`setDeskVariant`).
        desk_variant: ?pane_style.Variant = null,
        desk_variant_decided: bool = false,

        /// The desk, rendered small and stretched over the window's content
        /// (T3623: the window paints it, so it runs under the header bar and
        /// the pane sidebar too), cached per size/seed/theme. Owned.
        desk_texture: ?*wk.GdkTexture = null,
        desk_key: pane_style.DeskKey = .{},
        /// The seed of the desk last drawn (0: the ocean), and whether one
        /// was: in single mode the toplevel draws the desk of the workspace
        /// on show (T3651), and the `workspaces` seam reads which.
        desk_drawn_seed: u64 = 0,
        desk_drawn: bool = false,

        /// The shade crossfade on a workspace switch (T3651; Mac
        /// `PaneDeskEntrance`/`PaneDeskFade`, win32 T3183): the desk of the
        /// workspace that left, drawn over the new one at `fade_keep`/255
        /// and eased out over `desk_fade.duration_ms` on the frame clock.
        /// Only ever on the toplevel. Owned.
        fade_texture: ?*wk.GdkTexture = null,
        fade_from_seed: u64 = 0,
        fade_t0_us: i64 = 0,
        fade_keep: u8 = 0,
        fade_tick: c_uint = 0,
        /// Counters for the seam: fades begun, and frames DRAWN with the old
        /// desk laid on (the pixels' own count, not the clock's).
        fades_started: u32 = 0,
        fade_frames: u32 = 0,

        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// State and logic for windowing protocol for a window.
        winproto: winprotopkg.Window,

        /// Kind of hacky to have this but this lets us know if we've
        /// initialized any single surface yet. We need this because we
        /// gate default size on this so that we don't resize the window
        /// after surfaces already exist.
        ///
        /// I think long term we can probably get rid of this by implementing
        /// a property or method that gets us all the surfaces in all the
        /// tabs and checking if we have zero or one that isn't initialized.
        ///
        /// For now, this logic is more similar to our legacy GTK side.
        surface_init: bool = false,

        /// See tabOverviewOpen for why we have this.
        tab_overview_focus_timer: ?c_uint = null,

        /// A weak reference to a command palette.
        command_palette: WeakRef(CommandPalette) = .empty,

        /// Tab page that the context menu was opened for.
        /// setup by `setup-menu`.
        context_menu_page: ?*adw.TabPage = null,

        // Template bindings
        tab_overview: *adw.TabOverview,
        tab_bar: *adw.TabBar,
        tab_view: *adw.TabView,
        toolbar: *adw.ToolbarView,
        toast_overlay: *adw.ToastOverlay,
        sidebar_row: *gtk.Box,
        /// The main menu both menu buttons show (T3640's seam reads it).
        main_menu: *gio.Menu,

        pub var offset: c_int = 0;
    };

    pub fn new(
        app: *Application,
        overrides: struct {
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *Self {
        const win = gobject.ext.newInstance(Self, .{
            .application = app,
        });

        if (overrides.title) |title| {
            // If the overrides have a title set, we set that immediately
            // so that any applications inspecting the window states see an
            // immediate title set when the window appears, rather than waiting
            // possibly a few event loop ticks for it to sync from the surface.
            win.as(gtk.Window).setTitle(title);
        }

        return win;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();

        const config = config: {
            if (priv.config) |config| break :config config.get();
            const app = Application.default();
            const config = app.getConfig();
            priv.config = config;
            break :config config.get();
        };

        // We initialize our windowing protocol to none because we can't
        // actually initialize this until we get realized.
        priv.winproto = .none;

        // Add our dev CSS class if we're in debug mode.
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        // The title follows the selected tab through `syncTitle` (T3561),
        // not a property binding: it carries the activity suffix too.

        // Set our window icon. We can't set this in the blueprint file
        // because its dependent on the build config.
        self.as(gtk.Window).setIconName(build_config.bundle_id);

        // Initialize our actions
        self.initActionMap();

        // T3648: the content root names its workspace, so every lookup from
        // a widget inside it reaches this Window wherever the content is.
        gobject.Object.setData(
            self.contentRoot().as(gobject.Object),
            workspace_qdata_key,
            self,
        );

        // T3571: a window that is hidden (a quick terminal put away) or shown
        // again recomputes whether its panes can be seen.
        _ = gtk.Widget.signals.map.connect(self.as(gtk.Widget), *Self, windowMapChanged, self, .{});
        _ = gtk.Widget.signals.unmap.connect(self.as(gtk.Widget), *Self, windowMapChanged, self, .{});

        // Start states based on config.
        if (config.maximize) self.as(gtk.Window).maximize();
        if (config.fullscreen != .false) self.as(gtk.Window).fullscreen();

        // If we have an explicit title set, we set that immediately
        // so that any applications inspecting the window states see
        // an immediate title set when the window appears, rather than
        // waiting possibly a few event loop ticks for it to sync from
        // the surface.
        if (config.title) |title| {
            self.as(gtk.Window).setTitle(title);
        }

        // The pane sidebar (T3557): the shared flags are read once, before
        // the first window draws one, so a restored window starts as
        // `macos-pane-sidebar` says too.
        self.initPaneSidebar(config);

        // Escape leaves rearrange mode (T3564). Capture phase, so it is seen
        // before the focused pane's terminal would send it to the shell -
        // but only taken while the mode is on.
        {
            const keys = wk.gtk_event_controller_key_new();
            wk.gtk_event_controller_set_propagation_phase(keys, 1); // GTK_PHASE_CAPTURE
            _ = wk.g_signal_connect_data(keys, "key-pressed", @ptrCast(&rearrangeKeyPressed), self, null, 0);
            wk.gtk_widget_add_controller(@ptrCast(self), keys);
        }

        // The tab bar takes pane drops: a new tab at the index under the
        // pointer, and a 500ms rest on another tab opens it (T3615).
        PaneDrag.installDropTargetHover(@ptrCast(priv.tab_bar), self, &tabBarDrop, .{
            .motion = &tabBarMotion,
            .leave = &tabBarLeave,
        });

        // We always sync our appearance at the end because loading our
        // config and such can affect our bindings which are setup initially
        // in initTemplate.
        self.syncAppearance();

        // We need to do this so that the title initializes properly,
        // I think because its a dynamic getter.
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    /// Setup our action map.
    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("about", actionAbout, null),
            .init("close", actionClose, null),
            .init("close-tab", actionCloseTab, s_variant_type),
            .init("new-tab", actionNewTab, null),
            .init("new-window", actionNewWindow, null),
            .init("prompt-surface-title", actionPromptSurfaceTitle, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-context-tab-title", actionPromptContextTabTitle, null),
            .init("ring-bell", actionRingBell, null),
            .init("split-right", actionSplitRight, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("split-down", actionSplitDown, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            // TODO: accept the surface that toggled the command palette
            .init("toggle-command-palette", actionToggleCommandPalette, null),
            .init("toggle-inspector", actionToggleInspector, null),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Winproto backend for this window.
    pub fn winproto(self: *Self) *winprotopkg.Window {
        return &self.private().winproto;
    }

    /// Create a new tab with the given parent. The tab will be inserted
    /// at the position dictated by the `window-new-tab-position` config.
    /// The new tab will be selected.
    pub fn newTab(self: *Self, parent_: ?*CoreSurface) void {
        _ = self.newTabPage(parent_, .tab, .none);
    }

    /// A tab rebuilt by a session restore (T3397): its first pane is a
    /// viewer on `view`, or with null a terminal that adopts
    /// `Surface.pending_restore`. Returns the new tab.
    pub fn newTabForRestore(self: *Self, view: ?[:0]const u8) ?*Tab {
        const page = self.newTabPage(null, .tab, .{ .view = view });
        return gobject.ext.cast(Tab, page.getChild());
    }

    pub fn newTabForWindow(
        self: *Self,
        parent_: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,
            env: []const []const u8 = &.{},
            view: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) void {
        _ = self.newTabPage(
            parent_,
            .window,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
                .env = overrides.env,
                .view = overrides.view,
            },
        );
    }

    fn newTabPage(
        self: *Self,
        parent_: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,
            env: []const []const u8 = &.{},
            view: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *adw.TabPage {
        const priv: *Private = self.private();
        const tab_view = priv.tab_view;

        // T3668: a plain new tab in a window riding a remote machine opens a
        // fresh session on that SAME machine, in the active pane's remote cwd
        // and running its command (win32 `addTab`'s T68 inheritance, the
        // Mac's). A restore or a remote open that already set the handoff
        // keeps its own.
        var inherit: ?RemoteTabInherit = null;
        defer if (inherit) |*i| i.deinit();
        if (context == .tab and overrides.view == null and
            RemoteLink.pending_open == null and Surface.pending_restore == null)
        {
            inherit = self.remoteTabInherit(parent_);
            if (inherit) |i| RemoteLink.pending_open = i.open;
        }
        // Surface.new consumes the handoff; never let it outlive this call.
        defer if (inherit != null) {
            RemoteLink.pending_open = null;
        };

        // Create our new tab object
        const tab = Tab.new(
            priv.config,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
                .env = overrides.env,
                .view = overrides.view,
            },
        );

        if (parent_) |p| {
            // For a new window's first tab, inherit the parent's initial size hints.
            if (context == .window) {
                surfaceInit(p.rt_surface.gobj(), self);
            }
            tab.setParentWithContext(p, context);
        }

        // Get the position that we should insert the new tab at.
        const config = if (priv.config) |v| v.get() else {
            // If we don't have a config we just append it at the end.
            // This should never happen.
            return tab_view.append(tab.as(gtk.Widget));
        };
        const position = switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },

            .end => tab_view.getNPages(),
        };

        return self.attachTabPage(tab, position);
    }

    const RemoteTabInherit = struct {
        open: RemoteLink.Open,
        /// The remote cwd the query returned, owned by the link's
        /// connection allocator.
        cwd: ?[]u8 = null,

        fn deinit(self: *RemoteTabInherit) void {
            if (self.cwd) |c| self.open.link.conn().alloc.free(c);
        }
    };

    /// The remote open a new tab in this window inherits (T3668), or null
    /// for a local window. The source is `parent_`, else the active pane;
    /// a pane riding no link, or a retired one, makes the tab local.
    fn remoteTabInherit(self: *Self, parent_: ?*CoreSurface) ?RemoteTabInherit {
        const source: *Surface = if (parent_) |p|
            p.rt_surface.surface
        else
            self.getActiveSurface() orelse return null;
        const link = source.remoteLink() orelse return null;
        if (link.retired) return null;
        var result: RemoteTabInherit = .{ .open = .{ .link = link } };
        if (source.core()) |core| {
            // Borrowed for the one Surface.new; adoptRemote copies it.
            result.open.command = core.remoteCommand();
            if (core.remoteSessionId()) |sid| {
                result.cwd = link.conn().queryCwdTimeout(sid, 1500 * std.time.ns_per_ms) catch |err| c: {
                    log.debug("remote tab: cwd query failed err={}", .{err});
                    break :c null;
                };
                result.open.working_directory = result.cwd;
            }
        }
        log.info("new tab in a remote window: opening on {s}", .{link.machine.displayName()});
        return result;
    }

    /// Put `tab` into this window's tab view at `position`, select it, and
    /// wire it up: the page's title and tooltip, and the tree's changes. A
    /// new tab and a closed tab an undo brings back (T3590) both come here.
    fn attachTabPage(self: *Self, tab: *Tab, position: c_int) *adw.TabPage {
        const tab_view = self.private().tab_view;

        // Add the page and select it
        const page = tab_view.insert(tab.as(gtk.Widget), position);
        tab_view.setSelectedPage(page);

        // Create some property bindings
        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );

        // Bind signals
        const split_tree = tab.getSplitTree();
        _ = SplitTree.signals.changed.connect(
            split_tree,
            *Self,
            tabSplitTreeChanged,
            self,
            .{},
        );

        // Run an initial notification for the surface tree so we can setup
        // initial state.
        tabSplitTreeChanged(
            split_tree,
            null,
            split_tree.getTree(),
            self,
        );

        return page;
    }

    /// Put a closed tab back at `position` (clamped), selected, with focus
    /// on the pane it had (T3590). The caller keeps its own reference.
    pub fn restoreParkedTab(self: *Self, tab: *Tab, position: c_int) void {
        const tab_view = self.private().tab_view;
        const n = tab_view.getNPages();
        _ = self.attachTabPage(tab, @max(0, @min(position, n)));
        if (tab.getActiveSurface()) |s| tab.getSplitTree().focusSurface(s);
    }

    /// A tab being parked for undo (T3590) stops reporting its tree's
    /// changes here: it is no longer in this window. `attachTabPage` wires
    /// them again when it comes back.
    pub fn detachParkedTab(self: *Self, tab: *Tab) void {
        _ = gobject.signalHandlersDisconnectMatched(
            tab.getSplitTree().as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );
    }

    /// Close `tab` with no confirmation (a redo, or the tab's only pane
    /// closing, which the pane's own close already confirmed). With undo on
    /// it is parked like any other tab close. False when it is not here.
    pub fn closeTabNow(self: *Self, tab: *Tab) bool {
        if (ext.getAncestor(Self, tab.as(gtk.Widget)) != self) return false;
        const tab_view = self.private().tab_view;
        const page = tab_view.getPage(tab.as(gtk.Widget));
        CloseUndo.confirmed_tab = tab;
        defer CloseUndo.confirmed_tab = null;
        tab_view.closePage(page);
        return true;
    }

    /// Finish closing `page` (its confirmation, if any, answered yes),
    /// parking its tab for undo first when undo is on (T3590).
    fn finishTabClose(self: *Self, page: *adw.TabPage) void {
        const tab_view = self.private().tab_view;
        if (gobject.ext.cast(Tab, page.getChild())) |tab| {
            _ = CloseUndo.parkTab(self, tab, tab_view.getPagePosition(page));
        }
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    /// Select the tab as requested. Returns true if the tab selection
    /// changed.
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // Get our current tab numeric position
        const selected = tab_view.getSelectedPage() orelse return false;
        const current = tab_view.getPagePosition(selected);

        // Get our total
        const total = tab_view.getNPages();

        const goto: c_int = switch (n) {
            .previous => if (current > 0)
                current - 1
            else
                total - 1,

            .next => if (current < total - 1)
                current + 1
            else
                0,

            .last => total - 1,

            .n => |v| n: {
                // 1-indexed
                if (v == 0) return false;

                const n_int = std.math.cast(
                    c_int,
                    v,
                ) orelse return false;
                break :n @min(n_int - 1, total - 1);
            },
        };
        assert(goto >= 0);
        assert(goto < total);

        // If our target is the same as our current then we do nothing.
        if (goto == current) return false;

        // Add the page and select it
        const page = tab_view.getNthPage(goto);
        tab_view.setSelectedPage(page);

        return true;
    }

    /// Move the tab containing the given surface by the given amount.
    /// Returns if this affected any tab positioning.
    pub fn moveTab(
        self: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // If we have one tab we never move.
        const total = tab_view.getNPages();
        if (total == 1) return false;

        // Get the tab that contains the given surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;

        // Get the page position that contains the tab.
        const page = tab_view.getPage(tab.as(gtk.Widget));
        const pos = tab_view.getPagePosition(page);

        // Move it
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        assert(desired_pos >= 0);
        assert(desired_pos < total);

        return tab_view.reorderPage(page, desired_pos) != 0;
    }

    pub fn toggleTabOverview(self: *Self) void {
        const priv = self.private();
        const tab_overview = priv.tab_overview;
        const is_open = tab_overview.getOpen() != 0;
        tab_overview.setOpen(@intFromBool(!is_open));
    }

    /// Toggle the visible property.
    pub fn toggleVisibility(self: *Self) void {
        const widget = self.as(gtk.Widget);
        widget.setVisible(@intFromBool(widget.isVisible() == 0));
    }

    /// Updates various appearance properties. This should always be safe
    /// to call multiple times. This should be called whenever a change
    /// happens that might affect how the window appears (config change,
    /// fullscreen, etc.).
    fn syncAppearance(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);

        // Toggle style classes based on whether we're using CSDs or SSDs.
        //
        // These classes are defined in the gtk.Window documentation:
        // https://docs.gtk.org/gtk4/class.Window.html#css-nodes.
        {
            // Reset all style classes first
            inline for (&.{
                "ssd",
                "csd",
                "solid-csd",
                "no-border-radius",
            }) |class|
                widget.removeCssClass(class);

            const csd_enabled = priv.winproto.clientSideDecorationEnabled();
            self.as(gtk.Window).setDecorated(@intFromBool(csd_enabled));

            if (csd_enabled) {
                const display = widget.getDisplay();

                // We do the exact same check GTK is doing internally and toggle
                // either the `csd` or `solid-csd` style, based on whether the user's
                // window manager is deemed _non-compositing_.
                //
                // In practice this only impacts users of traditional X11 window
                // managers (e.g. i3, dwm, awesomewm, etc.) and not X11 desktop
                // environments or Wayland compositors/DEs.
                if (display.isRgba() != 0 and display.isComposited() != 0) {
                    widget.addCssClass("csd");
                } else {
                    widget.addCssClass("solid-csd");
                }
            } else {
                widget.addCssClass("ssd");
                // Fix any artifacting that may occur in window corners.
                widget.addCssClass("no-border-radius");
            }
        }

        // Trigger all our dynamic properties that depend on the config.
        inline for (&.{
            "headerbar-visible",
            "tabs-autohide",
            "tabs-visible",
            "tabs-wide",
            "toolbar-style",
            "titlebar-style",
        }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }

        // Remainder uses the config
        const config = if (priv.config) |v| v.get() else return;

        // Only add a solid background if we're opaque.
        self.toggleCssClass(
            "background",
            config.@"background-opacity" >= 1,
        );

        // Apply class to color headerbar if window-theme is set to `ghostty` and
        // GTK version is before 4.16. The conditional is because above 4.16
        // we use GTK CSS color variables.
        self.toggleCssClass(
            "window-theme-ghostty",
            !gtk_version.atLeast(4, 16, 0) and
                config.@"window-theme" == .ghostty,
        );

        // Move the tab bar to the proper location.
        priv.toolbar.remove(priv.tab_bar.as(gtk.Widget));
        switch (config.@"gtk-tabs-location") {
            .top => priv.toolbar.addTopBar(priv.tab_bar.as(gtk.Widget)),
            .bottom => priv.toolbar.addBottomBar(priv.tab_bar.as(gtk.Widget)),
        }

        // Do our window-protocol specific appearance sync.
        priv.winproto.syncAppearance() catch |err| {
            log.warn("failed to sync winproto appearance error={}", .{err});
        };

        // `macos-pane-style` applies to every window at once, a reload
        // included (T3566): re-mark every tab's cards and redraw its desk.
        self.syncPaneStyle();
    }

    /// Re-apply the pane style to every tab: the cards' classes and the desk.
    pub fn syncPaneStyle(self: *Self) void {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const tab = gobject.ext.cast(Tab, priv.tab_view.getNthPage(i).getChild()) orelse continue;
            const tree = tab.getSplitTree();
            tree.syncPaneStyle();
            tree.as(gtk.Widget).queueDraw();
        }
        // The window paints the desk (T3623), so its classes follow too.
        const config_obj = Application.default().getConfig();
        defer config_obj.unref();
        self.syncDeskClasses(config_obj.get());
    }

    /// Sync the state of any actions on this window.
    fn syncActions(self: *Self) void {
        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };

        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }

    fn toggleCssClass(self: *Self, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Perform a binding action on the window's active surface.
    fn performBindingAction(
        self: *Self,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse {
            // A viewer pane has no core surface: its entry takes the same
            // route its chord would (T3430), so the palette works over a
            // viewer, and over a window of nothing but viewers.
            if (surface.isViewer()) _ = Application.default().performViewerAction(surface, action);
            return;
        };
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    /// Queue a simple text-based toast. All text-based toasts share the
    /// same timeout for consistency.
    ///
    // This is not `pub` because we should be using signals emitted by
    // other widgets to trigger our toasts. Other objects should not
    // trigger toasts directly.
    fn addToast(self: *Self, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }

    fn connectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        const priv = self.private();
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            // Before adding any new signal handlers, disconnect any that we may
            // have added before. Otherwise we may get multiple handlers for the
            // same signal.
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );

            _ = Surface.signals.@"present-request".connect(
                surface,
                *Self,
                surfacePresentRequest,
                self,
                .{},
            );
            _ = Surface.signals.@"clipboard-write".connect(
                surface,
                *Self,
                surfaceClipboardWrite,
                self,
                .{},
            );
            _ = Surface.signals.menu.connect(
                surface,
                *Self,
                surfaceMenu,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-fullscreen".connect(
                surface,
                *Self,
                surfaceToggleFullscreen,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-maximize".connect(
                surface,
                *Self,
                surfaceToggleMaximize,
                self,
                .{},
            );
            // A pane's name and directory are its sidebar row (T3557).
            inline for (.{ "title", "title-override", "pwd" }) |detail| {
                _ = gobject.Object.signals.notify.connect(surface, *Self, sidebarSurfaceNotify, self, .{ .detail = detail });
            }

            // If we've never had a surface initialize yet, then we register
            // this signal. Its theoretically possible to launch multiple surfaces
            // before init so we could register this on multiple and that is not
            // a problem because we'll check the flag again in each handler.
            if (!priv.surface_init) {
                _ = Surface.signals.init.connect(
                    surface,
                    *Self,
                    surfaceInit,
                    self,
                    .{},
                );
            }
        }
    }

    /// Disconnect all the surface handlers for the given tree. This should
    /// be called whenever a tree is no longer present in the window, e.g.
    /// when a tab is detached or the tree changes.
    fn disconnectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Whether this terminal is a quick terminal or not.
    pub fn isQuickTerminal(self: *Self) bool {
        return self.private().quick_terminal;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tab = self.getSelectedTab() orelse return null;
        return tab.getActiveSurface();
    }

    /// The window's IPC name (T3370), or null before one is given.
    pub fn ipcName(self: *Self) ?[]const u8 {
        return self.private().ipc_name;
    }

    /// Give the window an IPC name (the IPC handlers keep it unique).
    pub fn setIpcName(self: *Self, name: ?[]const u8) void {
        const alloc = Application.default().allocator();
        const priv = self.private();
        if (priv.ipc_name) |v| alloc.free(v);
        priv.ipc_name = null;
        if (name) |n| priv.ipc_name = alloc.dupe(u8, n) catch null;
    }

    /// The title a script pinned (T3370), or null.
    pub fn titleOverride(self: *Self) ?[]const u8 {
        return self.private().title_override;
    }

    /// Pin the window's title, or with null (or "") let the active tab's
    /// title through again (T92: an empty title clears, never pins "").
    pub fn setTitleOverride(self: *Self, title: ?[]const u8) void {
        const alloc = Application.default().allocator();
        const priv = self.private();
        if (priv.title_override) |v| alloc.free(v);
        priv.title_override = null;
        const t = title orelse "";
        if (t.len > 0) priv.title_override = alloc.dupeZ(u8, t) catch null;
        self.syncTitle();
    }

    /// Returns the configuration for this window. The reference count
    /// is not increased.
    pub fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }

    /// Get the tab view for this window.
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }

    /// Get the current window decoration value for this window.
    pub fn getWindowDecoration(self: *Self) configpkg.WindowDecoration {
        const priv = self.private();
        if (priv.window_decoration) |v| return v;
        if (priv.config) |v| return v.get().@"window-decoration";
        return .auto;
    }

    /// Toggle the window decorations for this window.
    pub fn toggleWindowDecorations(self: *Self) void {
        const priv = self.private();

        if (priv.window_decoration) |_| {
            // Unset any previously set window decoration settings
            self.setWindowDecoration(null);
            return;
        }

        const config = if (priv.config) |v| v.get() else return;
        self.setWindowDecoration(switch (config.@"window-decoration") {
            // Use auto when the decoration is initially none
            .none => .auto,

            // Anything non-none to none
            .auto, .client, .server => .none,
        });
    }

    /// Set the window decoration override for this window. If this is null,
    /// then we'll revert back to the configuration's default.
    fn setWindowDecoration(
        self: *Self,
        new_: ?configpkg.WindowDecoration,
    ) void {
        const priv = self.private();
        priv.window_decoration = new_;
        self.syncAppearance();
    }

    /// Get the currently selected tab as a Tab object.
    pub fn getSelectedTab(self: *Self) ?*Tab {
        const priv = self.private();
        const page = priv.tab_view.getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        return gobject.ext.cast(Tab, child);
    }

    // ---- The pane sidebar (T3557) ------------------------------------------

    fn initPaneSidebar(self: *Self, config: *const configpkg.Config) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        PaneSidebar.loadShared(alloc, config.@"macos-pane-sidebar");
        const sidebar = PaneSidebar.create(alloc, self) catch |err| {
            log.warn("pane sidebar could not be created err={}", .{err});
            return;
        };
        priv.pane_sidebar = sidebar;
        priv.sidebar_row.prepend(@ptrCast(@alignCast(sidebar.card)));
        // Its header names the window, and a narrow window takes the rail.
        inline for (.{ "title", "default-width", "maximized", "fullscreened", "quick-terminal" }) |detail| {
            _ = gobject.Object.signals.notify.connect(self, *Self, sidebarWindowNotify, self, .{ .detail = detail });
        }
        sidebar.queueRefresh();
    }

    fn sidebarWindowNotify(_: *Self, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.queueSidebarRefresh();
    }

    fn sidebarSurfaceNotify(_: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.queueSidebarRefresh();
    }

    fn sidebarTabNotify(_: *Tab, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.queueSidebarRefresh();
    }

    /// Redraw this window's pane sidebar on the next idle turn: its panes,
    /// their names or its focus changed. In the all-windows scope (T3558)
    /// every window's list shows this window too, so every window redraws.
    pub fn queueSidebarRefresh(self: *Self) void {
        if (!PaneSidebar.scope.all_windows) {
            if (self.private().pane_sidebar) |s| s.queueRefresh();
            return;
        }
        queueAllSidebarRefresh();
    }

    /// Queue a redraw of every window's sidebar (a window opened or closed
    /// while the all-windows list is shown).
    pub fn queueAllSidebarRefresh() void {
        var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
        while (node) |n| {
            node = n.f_next;
            const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
            const win = gobject.ext.cast(Self, obj) orelse continue;
            if (win.private().pane_sidebar) |s| s.queueRefresh();
        }
    }

    /// This window's pane sidebar (the debug seam reads it).
    pub fn paneSidebar(self: *Self) ?*PaneSidebar {
        return self.private().pane_sidebar;
    }

    /// The shared sidebar flags moved: every window redraws its sidebar now.
    pub fn refreshAllSidebars() void {
        var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
        while (node) |n| {
            node = n.f_next;
            const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
            const win = gobject.ext.cast(Self, obj) orelse continue;
            if (win.private().pane_sidebar) |s| s.refresh();
        }
    }

    // ---- The gradient desk (T3566) ------------------------------------------

    /// The window's gradient: its own variant, or null for the shared ocean.
    /// A window nobody gave one to is a hand-opened window, so the first ask
    /// decides it from `macos-pane-style` / `macos-window-gradient`.
    pub fn deskVariant(self: *Self) ?pane_style.Variant {
        const priv = self.private();
        if (!priv.desk_variant_decided) {
            const c = priv.config orelse return null;
            priv.desk_variant_decided = true;
            const cfg = c.get();
            priv.desk_variant = pane_style.variantForNewWindow(
                paneStyleOf(cfg),
                switch (cfg.@"macos-window-gradient") {
                    .random => .random,
                    .ocean => .ocean,
                },
            );
        }
        return priv.desk_variant;
    }

    /// Give the window its gradient (`+new-window --color`: a random one for
    /// `random`, the ocean otherwise), over the hand-opened default.
    pub fn setDeskVariant(self: *Self, variant: ?pane_style.Variant) void {
        const priv = self.private();
        priv.desk_variant = variant;
        priv.desk_variant_decided = true;
        self.as(gtk.Widget).queueDraw();
        // In single mode the toplevel draws the desk of the workspace on
        // show (T3651), so a new gradient there is the toplevel's redraw.
        if (Workspaces.physical()) |t| if (t != self) t.as(gtk.Widget).queueDraw();
    }

    /// Render the desk for `variant` at a `w`x`h` window: the gradient at
    /// its small size, as a texture the snapshot stretches. Owned by the
    /// caller; null when out of memory.
    fn renderDeskTexture(w: i32, h: i32, variant: ?pane_style.Variant, is_light: bool) ?*wk.GdkTexture {
        const size = pane_style.deskSize(@intCast(w), @intCast(h));
        const alloc = Application.default().allocator();
        const buf = alloc.alloc(u32, size.w * size.h) catch return null;
        defer alloc.free(buf);
        pane_style.renderDesk(buf, size, @floatFromInt(w), @floatFromInt(h), pane_style.Palette.forWindow(variant, is_light));
        const bytes = wk.g_bytes_new(buf.ptr, buf.len * @sizeOf(u32));
        defer wk.g_bytes_unref(bytes);
        return wk.gdk_memory_texture_new(
            @intCast(size.w),
            @intCast(size.h),
            wk.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED,
            bytes,
            size.w * @sizeOf(u32),
        );
    }

    /// The toolbar view's bounds in the window, where the desk is drawn;
    /// null before it has a size. In single mode the toolbar is the one of
    /// the workspace on show (T3651): the toplevel's own left the window
    /// with its content, and measuring it drew no desk at all.
    fn deskArea(self: *Self) ?wk.GrapheneRect {
        const owner = Workspaces.deskOwner(self);
        var area: wk.GrapheneRect = .{};
        if (wk.gtk_widget_compute_bounds(@ptrCast(owner.private().toolbar), @ptrCast(self.as(gtk.Widget)), &area) == 0) return null;
        if (@round(area.w) <= 0 or @round(area.h) <= 0) return null;
        return area;
    }

    fn seedOf(variant: ?pane_style.Variant) u64 {
        return if (variant) |v| v.seed else 0;
    }

    /// Debug builds only: stretch the shade fade's clock N-fold, so the
    /// harness can capture frames from the middle of a 0.35s fade.
    const fade_stretch_env = "GHOZTTY_DEBUG_DESK_FADE_STRETCH";

    fn fadeStretch() i64 {
        if (comptime !build_config.is_debug) return 1;
        const raw = std.posix.getenv(fade_stretch_env) orelse return 1;
        const n = std.fmt.parseInt(i64, raw, 10) catch return 1;
        return std.math.clamp(n, 1, 1000);
    }

    /// A workspace switch put `to` on show in this toplevel (T3651; Mac
    /// `deskEntrance`, win32 `beginDeskFade`): fade from `from`'s gradient
    /// to `to`'s - the old desk drawn over the new and eased out over
    /// 0.35s - when one is owed: the elevated style (flat has no desk),
    /// animations on, and two different gradients. Otherwise the desk just
    /// swaps on the next frame.
    pub fn beginDeskFade(self: *Self, from: ?pane_style.Variant, to: ?pane_style.Variant) void {
        self.endDeskFade();
        const widget = self.as(gtk.Widget);
        widget.queueDraw();
        const config_obj = Application.default().getConfig();
        defer config_obj.unref();
        const cfg = config_obj.get();
        const elevated = pane_style.hasDesk(paneStyleOf(cfg));
        const animations = wk.adw_get_enable_animations(@ptrCast(widget)) != 0;
        if (!desk_fade.owed(pane_style.Variant, elevated, animations, from, to)) {
            log.info("workspace shade swap (no fade) from={d} to={d} elevated={} animations={}", .{ seedOf(from), seedOf(to), elevated, animations });
            return;
        }
        const priv = self.private();
        const bg = cfg.background;
        const is_light = pane_style.isLight(.{ .r = bg.r, .g = bg.g, .b = bg.b });
        const from_seed: ?u64 = if (from) |v| v.seed else null;
        // The desk the window showed until now is `from`'s: reuse it. The
        // new content is not laid out yet, so a desk rendered afresh takes
        // the size the last one was drawn at.
        const old: *wk.GdkTexture = if (priv.desk_texture != null and
            priv.desk_key.seed == from_seed and priv.desk_key.is_light == is_light)
            @ptrCast(wk.g_object_ref(priv.desk_texture.?))
        else old: {
            var w: i32 = @intCast(priv.desk_key.w);
            var h: i32 = @intCast(priv.desk_key.h);
            if (w <= 0 or h <= 0) {
                const area = self.deskArea() orelse {
                    log.info("workspace shade swap (no fade): the window has no desk area yet", .{});
                    return;
                };
                w = @intFromFloat(@round(area.w));
                h = @intFromFloat(@round(area.h));
            }
            break :old renderDeskTexture(w, h, from, is_light) orelse return;
        };
        priv.fade_texture = old;
        priv.fade_from_seed = seedOf(from);
        priv.fade_t0_us = wk.g_get_monotonic_time();
        priv.fade_keep = 255;
        priv.fades_started +%= 1;
        priv.fade_tick = wk.gtk_widget_add_tick_callback(@ptrCast(widget), &deskFadeTick, null, null);
        log.info("workspace shade fade from={d} to={d} stretch={d}", .{ seedOf(from), seedOf(to), fadeStretch() });
    }

    /// Drop the crossfade: the desk is the workspace on show's alone.
    fn endDeskFade(self: *Self) void {
        const priv = self.private();
        if (priv.fade_tick != 0) wk.gtk_widget_remove_tick_callback(@ptrCast(self.as(gtk.Widget)), priv.fade_tick);
        priv.fade_tick = 0;
        if (priv.fade_texture) |t| wk.g_object_unref(t);
        priv.fade_texture = null;
        priv.fade_keep = 0;
    }

    /// One frame of the crossfade on the frame clock: what is left of the
    /// old desk, redrawn; the last frame drops it.
    fn deskFadeTick(widget: *wk.GtkWidget, clock: *wk.GdkFrameClock, _: ?*anyopaque) callconv(.c) c_int {
        const self = gobject.ext.cast(Self, @as(*gobject.Object, @ptrCast(@alignCast(widget)))) orelse return 0;
        const priv = self.private();
        const now = wk.gdk_frame_clock_get_frame_time(clock);
        const elapsed_ms = @divTrunc(@divTrunc(now - priv.fade_t0_us, 1000), fadeStretch());
        const k = desk_fade.keep(elapsed_ms) orelse {
            // Returning 0 removes this callback; forget its id first.
            priv.fade_tick = 0;
            self.endDeskFade();
            self.as(gtk.Widget).queueDraw();
            log.info("workspace shade fade done frames={d}", .{priv.fade_frames});
            return 0;
        };
        if (k != priv.fade_keep) {
            priv.fade_keep = k;
            self.as(gtk.Widget).queueDraw();
        }
        return 1;
    }

    /// The `workspaces` seam's view of the desk (T3651).
    pub const DeskState = struct {
        drawn: bool,
        drawn_seed: u64,
        fade_on: bool,
        fade_from_seed: u64,
        fade_keep: u8,
        fades_started: u32,
        fade_frames: u32,
    };

    pub fn deskState(self: *Self) DeskState {
        const priv = self.private();
        return .{
            .drawn = priv.desk_drawn,
            .drawn_seed = priv.desk_drawn_seed,
            .fade_on = priv.fade_texture != null,
            .fade_from_seed = priv.fade_from_seed,
            .fade_keep = priv.fade_keep,
            .fades_started = priv.fades_started,
            .fade_frames = priv.fade_frames,
        };
    }

    /// The seed of this workspace's own gradient (0: the ocean).
    pub fn deskSeed(self: *Self) u64 {
        return seedOf(self.deskVariant());
    }

    /// Mark the window for `style.css` while it paints the desk (T3623): the
    /// header bar and tab bar go transparent over it, and on glass the pane
    /// sidebar becomes an unfocused pane's card.
    fn syncDeskClasses(self: *Self, cfg: *const configpkg.Config) void {
        const style = paneStyleOf(cfg);
        const desk = pane_style.hasDesk(style);
        const bg = cfg.background;
        const light = pane_style.isLight(.{ .r = bg.r, .g = bg.g, .b = bg.b });
        self.toggleCssClass(pane_style.window_class_desk, desk);
        self.toggleCssClass(pane_style.window_class_light, desk and light);
        self.toggleCssClass(pane_style.window_class_glass, pane_style.hasGlass(style, cfg.@"macos-pane-glass"));
        self.as(gtk.Widget).queueDraw();
    }

    /// The desk, behind the window's whole content (T3623; Mac: the desk sits
    /// behind the content stack, up under the transparent titlebar, and the
    /// expanded sidebar lets it through). Drawn over the toolbar view's
    /// bounds - header bar, tab bar, sidebar row - before any child, so the
    /// split tree's cards, the header and the sidebar all sit on it. On
    /// glass the sidebar card gets its pane sheet here, inside its corners.
    fn snapshotDesk(self: *Self, snap: *wk.GtkSnapshot) void {
        const priv = self.private();
        const config_obj = Application.default().getConfig();
        defer config_obj.unref();
        const cfg = config_obj.get();
        const style = paneStyleOf(cfg);
        if (!pane_style.hasDesk(style)) return;
        const widget = self.as(gtk.Widget);
        const area = self.deskArea() orelse return;
        const w: i32 = @intFromFloat(@round(area.w));
        const h: i32 = @intFromFloat(@round(area.h));
        const bg = cfg.background;
        const rgb: color_math.Rgb = .{ .r = bg.r, .g = bg.g, .b = bg.b };
        const is_light = pane_style.isLight(rgb);
        // In single mode this toplevel shows another workspace's content,
        // and the desk is that workspace's gradient (T3651; Mac: the desk
        // is the controller's, and the controller on show owns the window).
        const variant = Workspaces.deskOwner(self).deskVariant();

        const key: pane_style.DeskKey = .{
            .w = @intCast(w),
            .h = @intCast(h),
            .seed = if (variant) |v| v.seed else null,
            .is_light = is_light,
        };
        if (priv.desk_texture == null or !priv.desk_key.eql(key)) {
            const tex = renderDeskTexture(w, h, variant, is_light) orelse return;
            if (priv.desk_texture) |old| wk.g_object_unref(old);
            priv.desk_texture = tex;
            priv.desk_key = key;
        }
        wk.gtk_snapshot_append_scaled_texture(snap, priv.desk_texture.?, wk.GSK_SCALING_FILTER_LINEAR, &area);
        priv.desk_drawn = true;
        priv.desk_drawn_seed = seedOf(variant);

        // The shade crossfade (T3651): the old workspace's desk over it,
        // at what is left of it. Stretched over the same area, so a resize
        // mid-fade still covers the window.
        if (priv.fade_texture) |old| if (priv.fade_keep > 0) {
            wk.gtk_snapshot_push_opacity(snap, @as(f64, @floatFromInt(priv.fade_keep)) / 255.0);
            wk.gtk_snapshot_append_scaled_texture(snap, old, wk.GSK_SCALING_FILTER_LINEAR, &area);
            wk.gtk_snapshot_pop(snap);
            priv.fade_frames +%= 1;
        };

        // The sidebar card's glass sheet, inside its rounded corners.
        const sheet = pane_style.sidebarSheet(style, cfg.@"macos-pane-glass", rgb) orelse return;
        // The sidebar in the window: the workspace on show's (T3651).
        const sidebar = Workspaces.deskOwner(self).private().pane_sidebar orelse return;
        if (wk.gtk_widget_get_mapped(sidebar.card) == 0) return;
        var card: wk.GrapheneRect = .{};
        if (wk.gtk_widget_compute_bounds(sidebar.card, @ptrCast(widget), &card) == 0) return;
        if (card.w <= 0 or card.h <= 0) return;
        var rr: wk.GskRoundedRect = .{};
        _ = wk.gsk_rounded_rect_init_from_rect(&rr, &card, pane_style.sidebar_radius);
        wk.gtk_snapshot_push_rounded_clip(snap, &rr);
        const rgba: wk.GdkRGBA = .{ .red = sheet.r, .green = sheet.g, .blue = sheet.b, .alpha = sheet.a };
        wk.gtk_snapshot_append_color(snap, &rgba, &card);
        wk.gtk_snapshot_pop(snap);
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        self.snapshotDesk(@ptrCast(snap));
        gtk.Widget.virtual_methods.snapshot.call(Class.parent, self.as(Parent), snap);
    }

    pub fn paneStyleOf(cfg: *const configpkg.Config) pane_style.Style {
        return switch (cfg.@"macos-pane-style") {
            .elevated => .elevated,
            .flat => .flat,
        };
    }

    // ---- Pane rearrange mode (T3564) -----------------------------------------

    pub fn rearrangeMode(self: *Self) bool {
        return self.private().rearrange_mode;
    }

    /// `toggle_rearrange_mode` (Ctrl+Shift+., the command palette).
    pub fn toggleRearrangeMode(self: *Self) void {
        self.setRearrangeMode(!self.private().rearrange_mode);
    }

    /// Enter or leave rearrange mode: every pane of every tab shows or hides
    /// its header, and the tab bar is forced visible while it is on - it is a
    /// drop target (pane-rearrange.md).
    pub fn setRearrangeMode(self: *Self, on: bool) void {
        const priv = self.private();
        if (priv.rearrange_mode == on) return;
        priv.rearrange_mode = on;
        log.info("rearrange mode {s}", .{if (on) "on" else "off"});
        const n = priv.tab_view.getNPages();
        for (0..@intCast(n)) |i| {
            const tab = gobject.ext.cast(Tab, priv.tab_view.getNthPage(@intCast(i)).getChild()) orelse continue;
            tab.getSplitTree().syncRearrangeHeaders(on);
        }
        self.syncPopOut();
        inline for (&.{ "tabs-autohide", "tabs-visible" }) |key| {
            self.as(gobject.Object).notifyByPspec(@field(properties, key).impl.param_spec);
        }
    }

    /// The window's key handler for the mode: Escape, with no modifier,
    /// leaves it. Anything else, or Escape with the mode off, goes on to the
    /// pane. Also the `pane-drag` seam's way to press it.
    pub fn rearrangeKey(self: *Self, keyval: c_uint, state: c_uint) bool {
        const escape: c_uint = 0xff1b; // GDK_KEY_Escape
        const mods: c_uint = (1 << 0) | (1 << 2) | (1 << 3) | (1 << 26) | (1 << 27) | (1 << 28);
        if (!self.private().rearrange_mode) return false;
        if (keyval != escape or (state & mods) != 0) return false;
        self.setRearrangeMode(false);
        return true;
    }

    fn rearrangeKeyPressed(_: *wk.GtkEventController, keyval: c_uint, _: c_uint, state: c_uint, self: *Self) callconv(.c) c_int {
        // The controller is on the GtkWindow: in single-window mode that is
        // the shared toplevel, and the key is for the workspace on show in
        // it, not the toplevel's own (T3649).
        return @intFromBool(Workspaces.keyTarget(self).rearrangeKey(keyval, state));
    }

    // ---- Pane drops on the tab bar, and the tab dwell (T3615) -----------------

    /// Most tab buttons the drop geometry reads; tabs past it are not targets.
    pub const max_tab_buttons: usize = 64;

    /// The split tree of this window's tab that holds the pane `id`.
    pub fn splitTreeHolding(self: *Self, id: []const u8) ?*SplitTree {
        const tab_view = self.private().tab_view;
        const n = tab_view.getNPages();
        for (0..@intCast(n)) |i| {
            const tab = gobject.ext.cast(Tab, tab_view.getNthPage(@intCast(i)).getChild()) orelse continue;
            if (tab.getSplitTree().holds(id)) return tab.getSplitTree();
        }
        return null;
    }

    /// Where a dragged pane lives: its window and its tab's split tree.
    pub const PaneHome = struct { window: *Self, tree: *SplitTree };

    /// The window and split tree holding the pane `id`, looked for in
    /// `near` first and then in every other window of the app (T3616): a
    /// drag can end in any window, so its drop finds the source app-wide.
    pub fn paneHome(id: []const u8, near: *Self) ?PaneHome {
        if (near.splitTreeHolding(id)) |t| return .{ .window = near, .tree = t };
        var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
        while (node) |n| : (node = n.f_next) {
            const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
            const other = gobject.ext.cast(Self, obj) orelse continue;
            if (other == near) continue;
            if (other.splitTreeHolding(id)) |t| return .{ .window = other, .tree = t };
        }
        return null;
    }

    /// A pane drag from `source` window landed in this one (T3616; Mac
    /// `PaneMoveCoordinator.finishRelocation`). The panes in `moved` moved
    /// rather than closed, so a Disconnect's detach pin from the window they
    /// left does not follow them; and the mode follows the pane - a drag made
    /// in rearrange mode leaves the window it landed in rearrangeable too.
    /// `source_mode` is read before the move, since the window it left may
    /// have closed with its last pane. Then this window comes forward: the
    /// pane the user dropped here is the one that types.
    pub fn finishArrival(self: *Self, moved: []const *Surface, source_mode: bool) void {
        for (moved) |s| s.clearDetachPin();
        if (source_mode and !self.rearrangeMode()) self.setRearrangeMode(true);
        // A pane popped out to a new window: in single-window mode a new
        // workspace, on show (T3649).
        self.bringForward();
    }

    /// The selected tab's position, or null with none.
    pub fn selectedTabIndex(self: *Self) ?usize {
        const tab_view = self.private().tab_view;
        const page = tab_view.getSelectedPage() orelse return null;
        return @intCast(tab_view.getPagePosition(page));
    }

    /// The tab-bar dwell's armed tab, or null (the `pane-drag` seam).
    pub fn tabDwell(self: *Self) ?usize {
        return self.private().dwell_tab;
    }

    pub fn tabBarWidget(self: *Self) *wk.GtkWidget {
        return @ptrCast(self.private().tab_bar);
    }

    /// The tab bar as the resolver's candidate, in the bar's own
    /// coordinates: the strip and each tab's button, in tab order. Null
    /// while the bar is not on screen - a hidden bar is not a target
    /// (pane-rearrange.md: with the mode off that means one tab).
    pub fn tabBarCandidate(self: *Self, buf: *[max_tab_buttons]pane_drop.Rect) ?pane_drop.Candidate {
        const bar = self.tabBarWidget();
        if (wk.gtk_widget_get_mapped(bar) == 0) return null;
        const strip = PaneDrag.rectOf(bar, bar) orelse return null;
        const n = self.tabButtonRects(buf);
        return .{
            .window = @intFromPtr(self),
            .z_order = 0,
            .content_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            .pane_rects = &.{},
            .tab_bar_rect = strip,
            .tab_button_rects = buf[0..n],
        };
    }

    /// Each tab's button on the bar, in tab order, in the bar's coordinates.
    /// libadwaita draws a tab as an internal `AdwTab` widget, so they are
    /// found by type name and put in order left to right - the order the
    /// bar lays the pages out in. A tab the bar is still animating away
    /// (one more button than pages) cannot shift the ones after it past the
    /// page count: the count is the pages', and the extra is dropped.
    fn tabButtonRects(self: *Self, out: *[max_tab_buttons]pane_drop.Rect) usize {
        const bar = self.tabBarWidget();
        var n: usize = 0;
        collectTabButtons(self.private().tab_bar.as(gtk.Widget), bar, out, &n);
        std.mem.sort(pane_drop.Rect, out[0..n], {}, struct {
            fn lt(_: void, a: pane_drop.Rect, b: pane_drop.Rect) bool {
                return a.left < b.left;
            }
        }.lt);
        const pages: usize = @intCast(self.private().tab_view.getNPages());
        return @min(n, pages);
    }

    fn collectTabButtons(widget: *gtk.Widget, bar: *wk.GtkWidget, out: *[max_tab_buttons]pane_drop.Rect, n: *usize) void {
        var child = widget.getFirstChild();
        while (child) |c| : (child = c.getNextSibling()) {
            if (n.* == out.len) return;
            const class = c.as(gobject.Object).f_g_type_instance.f_g_class orelse continue;
            const name = std.mem.span(gobject.typeName(class.f_g_type) orelse "");
            if (std.mem.eql(u8, name, "AdwTab")) {
                if (c.getMapped() != 0) if (PaneDrag.rectOf(@ptrCast(c), bar)) |r| {
                    out[n.*] = r;
                    n.* += 1;
                };
                continue;
            }
            collectTabButtons(c, bar, out, n);
        }
    }

    fn tabBarDrop(owner: *anyopaque, dragged_id: []const u8, x: f64, y: f64) PaneDrag.DropResult {
        const self: *Self = @ptrCast(@alignCast(owner));
        return self.dropOnTabBar(dragged_id, x, y);
    }

    fn tabBarMotion(owner: *anyopaque, x: f64, y: f64) void {
        const self: *Self = @ptrCast(@alignCast(owner));
        self.tabDwellAt(x, y);
    }

    fn tabBarLeave(owner: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(owner));
        self.cancelTabDwell();
    }

    /// A pane released on the tab bar at (x, y), in the bar's coordinates:
    /// a new tab of its own at the index under the pointer, or - for a
    /// pane that is its tab's only one - that tab moved there (win32
    /// `canNewTabDrop`, Mac `.newTab`). A window's only pane stays put, so
    /// a drag never closes a window. The release and the `pane-drag` seam
    /// both come here.
    pub fn dropOnTabBar(self: *Self, dragged_id: []const u8, x: f64, y: f64) PaneDrag.DropResult {
        var buf: [max_tab_buttons]pane_drop.Rect = undefined;
        const cand = self.tabBarCandidate(&buf) orelse return .{};
        const point: pane_drop.Point = .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
        const target = pane_drop.resolve(point, &.{cand}, dragged_id, pane_drop.Metrics.forScale(1.0)) orelse return .{};
        if (target != .new_tab) return .{ .target = @tagName(target), .outcome = "not_here" };
        var result: PaneDrag.DropResult = .{ .target = "new_tab", .index = target.new_tab.index };

        const home = paneHome(dragged_id, self) orelse {
            result.outcome = "not_here";
            return result;
        };
        const source = home.tree;
        const surface = source.surfaceById(dragged_id) orelse {
            result.outcome = "not_here";
            return result;
        };

        // A pane of another window becomes a new tab of THIS window at the
        // index under the pointer (T3616; Mac `.newTab`, which allows it even
        // for a window's last pane: the pane lives on here, and the window it
        // emptied closes as any window does whose contents moved away).
        if (home.window != self) {
            result.outcome = if (self.adoptFromWindow(home, surface, target.new_tab.index)) "moved" else "not_here";
            log.info("tab bar drop pane={s} index={d} outcome={s} (from another window)", .{ dragged_id, target.new_tab.index, result.outcome });
            return result;
        }

        const tab_view = self.private().tab_view;
        const source_tab = ext.getAncestor(Tab, source.as(gtk.Widget)) orelse {
            result.outcome = "not_here";
            return result;
        };
        const page = tab_view.getPage(source_tab.as(gtk.Widget));
        const leaves: usize = leaves: {
            const tree = source.getTree() orelse break :leaves 0;
            var count: usize = 0;
            var it = tree.iterator();
            while (it.next()) |_| count += 1;
            break :leaves count;
        };
        const plan = pane_drop_apply.tabDrop(
            leaves,
            @intCast(tab_view.getPagePosition(page)),
            target.new_tab.index,
            @intCast(tab_view.getNPages()),
        );
        switch (plan) {
            .in_place => result.outcome = "in_place",
            .reorder => |to| {
                _ = tab_view.reorderPage(page, @intCast(to));
                tab_view.setSelectedPage(page);
                result.outcome = "moved";
            },
            .new_tab => |at| {
                result.outcome = if (self.movePaneToNewTab(source, surface, at)) "moved" else "not_here";
            },
        }
        log.info("tab bar drop pane={s} index={d} outcome={s}", .{ dragged_id, target.new_tab.index, result.outcome });
        return result;
    }

    /// Move `surface` out of `source` into a new tab of its own at
    /// `position`, selected and focused. The very same pane: its shell,
    /// scrollback and pane id go with it.
    fn movePaneToNewTab(self: *Self, source: *SplitTree, surface: *Surface, position: usize) bool {
        _ = surface.ref();
        defer surface.unref();
        const released = source.releaseSurface(surface) catch false;
        if (!released) return false;
        const tab = Tab.newAdopting(self.private().config, surface) catch |err| {
            // Out of memory with the pane already out of its tab: it closes,
            // as a pane does when its tab cannot be built (`Tab.new`).
            log.warn("new tab for a dropped pane failed err={}", .{err});
            return false;
        };
        const n = self.private().tab_view.getNPages();
        _ = self.attachTabPage(tab, @intCast(@min(@as(c_int, @intCast(position)), n)));
        tab.getSplitTree().focusSurface(surface);
        return true;
    }

    /// Move `surface`, a pane of ANOTHER window (`home`), into a new tab of
    /// this window at `position`, selected and focused (T3616). The same
    /// pane: shell, scrollback, pane id and agent session go with it. Its old
    /// tab closes when it was that tab's only pane, and its old window when
    /// that was the window's only tab - the source goes first and holds a
    /// reference through it, since closing may destroy it mid-call.
    fn adoptFromWindow(self: *Self, home: PaneHome, surface: *Surface, position: usize) bool {
        _ = surface.ref();
        defer surface.unref();
        const source_window = home.window;
        _ = source_window.as(gobject.Object).ref();
        defer source_window.as(gobject.Object).unref();
        const source_mode = source_window.rearrangeMode();

        const taken = home.tree.takeSurface(surface) catch false;
        if (!taken) return false;
        const tab = Tab.newAdopting(self.private().config, surface) catch |err| {
            log.warn("new tab for a pane from another window failed err={}", .{err});
            return false;
        };
        const n = self.private().tab_view.getNPages();
        _ = self.attachTabPage(tab, @intCast(@min(@as(c_int, @intCast(position)), n)));
        tab.getSplitTree().focusSurface(surface);
        self.finishArrival(&.{surface}, source_mode);
        return true;
    }

    /// How many panes `tree` holds (its leaves).
    fn leafCount(tree: *SplitTree) usize {
        const t = tree.getTree() orelse return 0;
        var count: usize = 0;
        var it = t.iterator();
        while (it.next()) |_| count += 1;
        return count;
    }

    /// May a pane of `tree`, a tab of this window, move into a new window
    /// of its own (T3618; `pane_drop_apply.popOutAllowed`)?
    pub fn popOutAllowedFor(self: *Self, tree: *SplitTree) bool {
        return pane_drop_apply.popOutAllowed(leafCount(tree), @intCast(self.private().tab_view.getNPages()));
    }

    /// Move the pane `id` into a NEW window holding only it (T3618, Mac
    /// "anywhere else: a new window" and the header's pop-out button): a
    /// drag released over nothing, or that button. The same pane - shell,
    /// scrollback, pane id and agent session go with it, through the
    /// cross-window adoption a drop on another window's tab bar makes
    /// (`adoptFromWindow`, which also brings the rearrange mode along and
    /// presents the new window). A window's last pane is refused, so this
    /// never closes a window. The new window opens at the size of the one
    /// it leaves; Wayland gives a client no pointer or window position, so
    /// where it lands is the compositor's call.
    pub fn popOutPane(id: []const u8, near: *Self) PaneDrag.DropResult {
        var result: PaneDrag.DropResult = .{ .target = "new_window", .outcome = "not_here" };
        const home = paneHome(id, near) orelse return result;
        const surface = home.tree.surfaceById(id) orelse return result;
        if (!home.window.popOutAllowedFor(home.tree)) {
            result.outcome = "refused";
            log.info("pop out pane={s} refused: the window's last pane", .{id});
            return result;
        }
        const src = home.window.as(gtk.Window);
        const src_w = home.window.as(gtk.Widget);
        var dw: c_int = 0;
        var dh: c_int = 0;
        src.getDefaultSize(&dw, &dh);
        const filling = src.isMaximized() != 0 or src.isFullscreen() != 0;
        const size = pane_drop_apply.popOutSize(src_w.getWidth(), src_w.getHeight(), filling, dw, dh);
        const win = Application.default().newWindowForPopOut(
            if (size) |s| s[0] else 0,
            if (size) |s| s[1] else 0,
        );
        if (!win.adoptFromWindow(home, surface, 0)) {
            // Nothing moved: the empty window goes again.
            win.as(gtk.Window).destroy();
            return result;
        }
        result.outcome = "moved";
        log.info("pop out pane={s} into a new window size={d}x{d}", .{
            id,
            if (size) |s| s[0] else 0,
            if (size) |s| s[1] else 0,
        });
        return result;
    }

    /// Re-read whether each pane's header may pop it out (T3618): the
    /// button is disabled on a window's last pane. Run when a tree rebuilds
    /// and when a tab comes or goes, since either changes the answer.
    pub fn syncPopOut(self: *Self) void {
        const tab_view = self.private().tab_view;
        const n = tab_view.getNPages();
        for (0..@intCast(n)) |i| {
            const tab = gobject.ext.cast(Tab, tab_view.getNthPage(@intCast(i)).getChild()) orelse continue;
            const tree = tab.getSplitTree();
            tree.syncPopOut(self.popOutAllowedFor(tree));
        }
    }

    /// A pane drag over the tab bar at (x, y), in the bar's coordinates:
    /// resting on another tab's button for 500ms selects that tab, so the
    /// drag can go on into its layout (Mac `PaneDropResolver.hoveredTab`,
    /// win32 T1537). The clock is re-armed only when the tab under the
    /// pointer CHANGES - one restarted by every move would never fire while
    /// the hand is moving. The tab already on show arms nothing.
    pub fn tabDwellAt(self: *Self, x: f64, y: f64) void {
        const priv = self.private();
        var buf: [max_tab_buttons]pane_drop.Rect = undefined;
        const want: ?usize = want: {
            const cand = self.tabBarCandidate(&buf) orelse break :want null;
            const point: pane_drop.Point = .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
            const hit = pane_drop.hoveredTab(point, &.{cand}) orelse break :want null;
            if (self.selectedTabIndex()) |sel| if (sel == hit.index) break :want null;
            break :want hit.index;
        };
        if (want) |w| if (priv.dwell_tab) |cur| if (cur == w) return;
        self.cancelTabDwell();
        const w = want orelse return;
        priv.dwell_tab = w;
        priv.dwell_timer = glib.timeoutAdd(tab_dwell_ms, onTabDwell, self);
    }

    /// The Mac's and win32's dwell: half a second.
    pub const tab_dwell_ms: c_uint = 500;

    /// Stop the dwell clock: the drag left the bar, dropped, or ended.
    pub fn cancelTabDwell(self: *Self) void {
        const priv = self.private();
        if (priv.dwell_timer) |t| _ = glib.Source.remove(t);
        priv.dwell_timer = null;
        priv.dwell_tab = null;
    }

    fn onTabDwell(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.dwell_timer = null;
        const i = priv.dwell_tab orelse return 0;
        priv.dwell_tab = null;
        const tab_view = priv.tab_view;
        if (i >= @as(usize, @intCast(tab_view.getNPages()))) return 0;
        tab_view.setSelectedPage(tab_view.getNthPage(@intCast(i)));
        log.info("pane drag dwell opened tab {d}", .{i});
        return 0;
    }

    /// Returns true if this window needs confirmation before quitting.
    fn getNeedsConfirmQuit(self: *Self) bool {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        assert(n >= 0);

        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child) orelse {
                log.warn("unexpected non-Tab child in tab view", .{});
                continue;
            };
            if (tab.getNeedsConfirmQuit()) return true;
        }

        return false;
    }

    /// Every pane in this window a Disconnect would spare (T3563).
    fn disconnectOffer(self: *Self) disconnect_offer.Offer {
        var offer: disconnect_offer.Offer = .{};
        const tab_view = self.private().tab_view;
        const n: usize = @intCast(tab_view.getNPages());
        for (0..n) |i| {
            const tab = gobject.ext.cast(Tab, tab_view.getNthPage(@intCast(i)).getChild()) orelse continue;
            tab.getSplitTree().addDisconnectOffer(&offer);
        }
        return offer;
    }

    fn isFullscreen(self: *Window) bool {
        return self.as(gtk.Window).isFullscreen() != 0;
    }

    fn isMaximized(self: *Window) bool {
        return self.as(gtk.Window).isMaximized() != 0;
    }

    fn getHeaderbarVisible(self: *Self) bool {
        const priv = self.private();

        // Never display the header bar when CSDs are disabled.
        const csd_enabled = priv.winproto.clientSideDecorationEnabled();
        if (!csd_enabled) return false;

        // Never display the header bar as a quick terminal.
        if (priv.quick_terminal) return false;

        // If we're fullscreen we never show the header bar.
        if (self.isFullscreen()) return false;

        // The remainder needs a config
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();

        // *Conditionally* disable the header bar when maximized, and
        // gtk-titlebar-hide-when-maximized is set
        if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") {
            return false;
        }

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs never show the titlebar.
            .tabs => false,

            // If the titlebar style is native show the titlebar if configured
            // to do so.
            .native => config.@"gtk-titlebar",
        };
    }

    pub fn getTabsAutohide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        // Rearrange mode keeps the tab bar up: it is a drop target (T3564).
        if (priv.rearrange_mode) return false;

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs we cannot autohide.
            .tabs => false,

            .native => switch (config.@"window-show-tab-bar") {
                // Auto we always autohide... obviously.
                .auto => true,

                // Always we never autohide because we always show the tab bar.
                .always => false,

                // Never we autohide because it doesn't actually matter,
                // since getTabsVisible will return false.
                .never => true,
            },
        };
    }

    pub fn getTabsVisible(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        // Rearrange mode forces the tab bar visible (T3564).
        if (priv.rearrange_mode) return true;

        switch (config.@"gtk-titlebar-style") {
            .tabs => {
                // *Conditionally* disable the tab bar when maximized, the titlebar
                // style is tabs, and gtk-titlebar-hide-when-maximized is set.
                if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") return false;

                // If the titlebar style is tabs the tab bar must always be visible.
                return true;
            },
            .native => {
                return switch (config.@"window-show-tab-bar") {
                    .always, .auto => true,
                    .never => false,
                };
            },
        }
    }

    fn getTabsWide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        return config.@"gtk-wide-tabs";
    }

    fn getToolbarStyle(self: *Self) adw.ToolbarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .raised;
        return switch (config.@"gtk-toolbar-style") {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
    }

    fn getTitlebarStyle(self: *Self) TitlebarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .native;
        return config.@"gtk-titlebar-style";
    }

    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.@"app-notifications".@"config-reload") {
                self.addToast(i18n._("Reloaded the configuration"));
            }
        }

        self.syncAppearance();
    }

    fn propIsActive(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Hide quick-terminal if set to autohide
        if (self.isQuickTerminal()) {
            if (self.getConfig()) |cfg| {
                if (cfg.get().@"quick-terminal-autohide" and
                    self.as(gtk.Window).isActive() == 0 and
                    self.as(gtk.Widget).isVisible() == 1)
                {
                    self.toggleVisibility();
                }
            }
        }

        // Don't change urgency if we're not the active window.
        if (self.as(gtk.Window).isActive() == 0) return;

        self.winproto().setUrgent(false) catch |err| {
            log.warn(
                "winproto failed to reset urgency={}",
                .{err},
            );
        };
    }

    fn propGdkSurfaceDims(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
        // T3650: parked workspaces follow the shared window once it settles.
        Workspaces.toplevelResized(self);
    }

    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Debian 12 is stuck on GTK 4.8
        if (!gtk_version.atLeast(4, 10, 0)) return;

        // We only care if we're activating. If we're activating then
        // we need to check the validity of our menu items.
        const active = button.getActive() != 0;
        if (!active) return;

        self.syncActions();
    }

    fn propQuickTerminal(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) {
            log.warn("quick terminal property can't be changed after surfaces have been initialized", .{});
            return;
        }

        if (priv.quick_terminal) {
            // Initialize the quick terminal at the app-layer
            Application.default().winproto().initQuickTerminal(self) catch |err| {
                log.warn("failed to initialize quick terminal error={}", .{err});
                return;
            };
        }
    }

    fn propScaleFactor(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // On some platforms (namely X11) we need to refresh our appearance when
        // the scale factor changes. In theory this could be more fine-grained as
        // a full refresh could be expensive, but a) this *should* be rare, and
        // b) quite noticeable visual bugs would occur if this is not present.
        self.private().winproto.syncAppearance() catch |err| {
            log.warn(
                "failed to sync appearance after scale factor has been updated={}",
                .{err},
            );
            return;
        };
    }

    fn closureTitlebarStyleIsTab(
        _: *Self,
        value: TitlebarStyle,
    ) callconv(.c) c_int {
        return @intFromBool(switch (value) {
            .native => false,
            .tabs => true,
        });
    }

    fn closureSubtitle(
        _: *Self,
        config_: ?*Config,
        pwd_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const config = if (config_) |v| v.get() else return null;
        return switch (config.@"window-subtitle") {
            .false => null,
            .@"working-directory" => pwd: {
                const pwd = pwd_ orelse return null;
                break :pwd glib.ext.dupeZ(u8, std.mem.span(pwd));
            },
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // T3648: before anything else, every workspace's content is back in
        // a window of its own, so none goes down with a toplevel it was
        // borrowing and this one's template disposes its own content.
        self.leaveWorkspace();

        // T3384: nothing can put this window's closed panes back now.
        CloseUndo.dropWindow(self);

        // T3671: a relay window closed outside a quit does not come back at
        // the next launch; one a quit tears down does.
        RelayWindows.windowDisposed(self, Application.default().isQuitting());

        priv.command_palette.set(null);

        // T3615: nor a drag's tab dwell.
        self.cancelTabDwell();

        // T3651: nor a shade fade's frame-clock tick.
        self.endDeskFade();

        // T3571: a held title's timer must not fire into a disposed window.
        if (priv.held_title_timer != 0) {
            _ = glib.Source.remove(priv.held_title_timer);
            priv.held_title_timer = 0;
        }

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        // Before the template's widgets go: it removes its rows from them.
        if (priv.pane_sidebar) |s| {
            s.destroy();
            priv.pane_sidebar = null;
            // The other windows' all-windows lists drop this one (T3558). A
            // window with no sidebar is never gathered, so the redraw cannot
            // reach into this one's disposed widgets.
            if (PaneSidebar.scope.all_windows) queueAllSidebarRefresh();
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.winproto.deinit();
        const alloc = Application.default().allocator();
        if (priv.ipc_name) |v| alloc.free(v);
        priv.ipc_name = null;
        if (priv.title_override) |v| alloc.free(v);
        priv.title_override = null;
        if (priv.held_title) |v| alloc.free(v);
        priv.held_title = null;
        if (priv.desk_texture) |t| wk.g_object_unref(t);
        priv.desk_texture = null;
        if (priv.fade_texture) |t| wk.g_object_unref(t);
        priv.fade_texture = null;

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn windowRealize(_: *gtk.Widget, self: *Window) callconv(.c) void {
        const app = Application.default();

        // Initialize our window protocol logic
        if (winprotopkg.Window.init(
            app.allocator(),
            app.winproto(),
            self,
        )) |wp| {
            self.private().winproto = wp;
        } else |err| {
            log.warn("failed to initialize window protocol error={}", .{err});
            return;
        }

        // We need to setup resize notifications on our surface,
        // which is only available after the window had been realized.
        if (self.as(gtk.Native).getSurface()) |gdk_surface| {
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "width" },
            );
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "height" },
            );
            // T3571: minimized / suspended decide whether anyone can see
            // this window's panes.
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkToplevelState,
                self,
                .{ .detail = "state" },
            );
        }

        // When we are realized we always setup our appearance since this
        // calls some winproto functions.
        self.syncAppearance();
    }

    fn btnNewTab(_: *adw.SplitButton, self: *Self) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn tabOverviewCreateTab(
        _: *adw.TabOverview,
        self: *Self,
    ) callconv(.c) *adw.TabPage {
        return self.newTabPage(if (self.getActiveSurface()) |v| v.core() else null, .tab, .none);
    }

    fn tabOverviewOpen(
        tab_overview: *adw.TabOverview,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We only care about when the tab overview is closed.
        if (tab_overview.getOpen() != 0) return;

        // On tab overview close, focus is sometimes lost. This is an
        // upstream issue in libadwaita[1]. When this is resolved we
        // can put a runtime version check here to avoid this workaround.
        //
        // Our workaround is to start a timer after 500ms to refocus
        // the currently selected tab. We choose 500ms because the adw
        // animation is 400ms.
        //
        // [1]: https://gitlab.gnome.org/GNOME/libadwaita/-/issues/670

        // If we have an old timer remove it
        const priv = self.private();
        if (priv.tab_overview_focus_timer) |timer| {
            _ = glib.Source.remove(timer);
        }

        // Restart our timer
        priv.tab_overview_focus_timer = glib.timeoutAdd(
            500,
            tabOverviewFocusTimer,
            self,
        );
    }

    fn tabOverviewFocusTimer(
        ud: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always note our timer is removed
        self.private().tab_overview_focus_timer = null;

        // Get our currently active surface which should respect the newly
        // selected tab. Grab focus.
        const surface = self.getActiveSurface() orelse return 0;
        surface.grabFocus();

        // Remove the timer
        return 0;
    }

    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        // T3652: the shared toplevel's close button (or the compositor's
        // close) closes the workspace ON SHOW in it, not the toplevel's own
        // workspace - which may be parked, or already gone (a frame).
        if (Workspaces.closeRequestTarget(self)) |target| {
            log.info("window close request on the shared window: it closes the workspace on show", .{});
            target.requestClose();
            return @intFromBool(true);
        }
        self.requestClose();
        return @intFromBool(true);
    }

    /// Close this window's own workspace as its close button would: ask
    /// first when something runs (T3563: a window on a remote machine asks
    /// even when idle, and offers Disconnect), else close it now.
    pub fn requestClose(self: *Self) void {
        if (self.private().frame_only) {
            // A frame with nothing on show in it has nothing to ask about.
            self.as(gtk.Window).destroy();
            return;
        }
        const offer = self.disconnectOffer();
        const step = disconnect_offer.step(self.getNeedsConfirmQuit(), offer);
        log.info("window close request: {s} ({d} remote session(s) to spare)", .{ @tagName(step), offer.count });
        switch (step) {
            .close => self.closeNow(),
            .ask_running => self.askToClose(null),
            .ask_disconnect => self.askToClose(offer),
        }
    }

    /// Close this window now, no question asked. In single-window mode the
    /// shared toplevel's own workspace closing while others are open closes
    /// the WORKSPACE and keeps the GtkWindow as their frame (T3652), so the
    /// person never sees the window go and another come.
    pub fn closeNow(self: *Self) void {
        if (Workspaces.retire(self)) return;
        self.as(gtk.Window).destroy();
    }

    /// Whether this window is only the shared toplevel's frame (T3652).
    pub fn isFrame(self: *Self) bool {
        return self.private().frame_only;
    }

    /// The shared toplevel's own workspace closed while others are open
    /// (T3652, `Workspaces.retire`): its content is already out of the
    /// window; end the workspace - its tabs, its undo entries, its sidebar,
    /// its relay record - and keep the GtkWindow as the frame.
    pub fn becomeFrame(self: *Self) void {
        const priv = self.private();
        if (priv.frame_only) return;
        priv.frame_only = true;

        // Its tabs end as a closed window's do (the close was confirmed
        // already); with undo on each is parked, and `dropWindow` below
        // ends them - window-close undo is T3665.
        const tab_view = priv.tab_view;
        while (tab_view.getNPages() > 0) {
            const page = tab_view.getNthPage(tab_view.getNPages() - 1);
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse {
                tab_view.closePageFinish(page, @intFromBool(true));
                continue;
            };
            if (!self.closeTabNow(tab)) break;
        }
        CloseUndo.dropWindow(self);
        RelayWindows.windowDisposed(self, false);
        self.cancelTabDwell();
        if (priv.pane_sidebar) |s| {
            s.destroy();
            priv.pane_sidebar = null;
        }
        // The held content's `win` group references this window: drop the
        // cycle, as `leaveWorkspace` does.
        self.contentRoot().insertActionGroup("win", null);
        self.setIpcName(null);
        queueAllSidebarRefresh();
        log.info("workspace: the shared window's own workspace closed; the window stays as the frame", .{});
    }

    /// Put the "Close Window?" confirmation up over this window, offering
    /// Disconnect when `offer` counts remote sessions (T3563). In
    /// single-window mode a parked workspace comes on show first, so the
    /// dialog has a window and the person sees what closes (T3652).
    fn askToClose(self: *Self, offer: ?disconnect_offer.Offer) void {
        if (Workspaces.isParked(self)) _ = Workspaces.show(self, true);
        const dialog: *CloseConfirmationDialog = .new(.window);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Self,
            closeConfirmationClose,
            self,
            .{},
        );
        if (offer) |o| {
            dialog.offerDisconnect(o);
            _ = CloseConfirmationDialog.signals.@"disconnect-request".connect(
                dialog,
                *Self,
                closeConfirmationDisconnect,
                self,
                .{},
            );
        }
        dialog.present(Workspaces.dialogParent(self));
    }

    /// Disconnect (T3563): close the window, its remote sessions pinned so
    /// they keep running. Still a deliberate close: a relay window's
    /// relaunch record goes (`RelayWindows.windowDisposed`).
    fn closeConfirmationDisconnect(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.private().tab_view;
        const n: usize = @intCast(tab_view.getNPages());
        for (0..n) |i| {
            const tab = gobject.ext.cast(Tab, tab_view.getNthPage(@intCast(i)).getChild()) orelse continue;
            tab.getSplitTree().pinRemoteDetach();
        }
        self.closeNow();
    }

    /// The GType name of the dialog up over this window, if any (the
    /// `close-dialog` seam's diagnostics).
    pub fn openDialogTypeName(self: *Self) ?[]const u8 {
        const open = self.openDialog() orelse return null;
        const obj: *gobject.Object = switch (open) {
            .adw => |d| d.as(gobject.Object),
            .window => |w| w.as(gobject.Object),
        };
        const class = obj.f_g_type_instance.f_g_class orelse return "?";
        return std.mem.span(gobject.typeName(class.f_g_type) orelse return "?");
    }

    /// The close confirmation up over this window, if one is (the
    /// `close-dialog` test seam, T3563).
    pub fn openCloseConfirmation(self: *Self) ?*CloseConfirmationDialog {
        const open = self.openDialog() orelse return null;
        const obj: *gobject.Object = switch (open) {
            .adw => |d| d.as(gobject.Object),
            .window => |w| w.as(gobject.Object),
        };
        return gobject.ext.cast(CloseConfirmationDialog, obj);
    }

    /// DEBUG-ONLY test seam (T3367): put the window's real close
    /// confirmation up, as a close request with a running program would.
    /// Wayland gives a test no input to press the close shortcut with, so
    /// this is the only way `test/linux/cli-close-focus.sh` can stand a
    /// dialog over a window. Compiled out of every release build.
    pub fn testAskToClose(self: *Self) void {
        if (comptime !build_config.is_debug) return;
        self.askToClose(null);
    }

    /// Whether a dialog (a close confirmation, a clipboard prompt...) is up
    /// over this window: the Mac's `attachedSheet`, win32's
    /// `ConfirmDialog.openOver` (T2938). `+close` refuses over one.
    pub fn hasOpenDialog(self: *Self) bool {
        return self.openDialog() != null;
    }

    /// Dismiss the dialog up over this window, unanswered (`+close --force`).
    /// True when there was one.
    pub fn dismissOpenDialog(self: *Self) bool {
        const open = self.openDialog() orelse return false;
        switch (open) {
            .adw => |d| d.forceClose(),
            .window => |w| w.destroy(),
        }
        return true;
    }

    const OpenDialog = union(enum) { adw: *adw.Dialog, window: *gtk.Window };

    fn openDialog(self: *Self) ?OpenDialog {
        // T3652: a workspace on show has its dialogs in the shared
        // toplevel; a parked one (and a frame) has none up.
        const host = Workspaces.dialogHost(self) orelse return null;
        // libadwaita 1.5+ hosts dialogs inside the window.
        if (comptime adw_version.supportsDialogs()) {
            if (host.as(adw.ApplicationWindow).getVisibleDialog()) |d| return .{ .adw = d };
        }
        // Before it (and for any plain transient window): a toplevel whose
        // transient-for is this window.
        const me = host.as(gtk.Window);
        const head: ?*glib.List = gtk.Window.listToplevels();
        defer if (head) |n| n.free();
        var it = head;
        while (it) |n| : (it = n.f_next) {
            const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
            const w = gobject.ext.cast(gtk.Window, obj) orelse continue;
            if (w == me) continue;
            if (w.getTransientFor() == me and w.as(gtk.Widget).getVisible() != 0) return .{ .window = w };
        }
        return null;
    }

    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.closeNow();
    }

    fn closeConfirmationCloseTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        if (ext.getAncestor(Self, tab_view.as(gtk.Widget))) |window| {
            window.finishTabClose(page);
            return;
        }
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    /// Disconnect (T3563): close the tab, its remote panes pinned so their
    /// sessions keep running.
    fn closeConfirmationDisconnectTab(
        dialog: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        if (gobject.ext.cast(Tab, page.getChild())) |tab| tab.getSplitTree().pinRemoteDetach();
        closeConfirmationCloseTab(dialog, page);
    }

    fn closeConfirmationCancelTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(false));
    }

    fn tabViewClosePage(
        _: *adw.TabView,
        page: *adw.TabPage,
        self: *Self,
    ) callconv(.c) c_int {
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse
            return @intFromBool(false);

        // If the tab says it doesn't need confirmation then we go ahead
        // and close immediately. So does one whose close was already
        // confirmed (its only pane's), or that a redo closes (T3590).
        // T3563: a tab on a remote machine asks even when idle.
        var offer: disconnect_offer.Offer = .{};
        if (CloseUndo.confirmed_tab != tab) tab.getSplitTree().addDisconnectOffer(&offer);
        if (CloseUndo.confirmed_tab == tab or
            disconnect_offer.step(tab.getNeedsConfirmQuit(), offer) == .close)
        {
            self.finishTabClose(page);
            return @intFromBool(true);
        }

        // Show a confirmation dialog
        log.info("tab close request: asking (disconnect offered: {})", .{offer.offered()});
        const dialog: *CloseConfirmationDialog = .new(.tab);
        if (offer.offered()) {
            dialog.offerDisconnect(offer);
            _ = CloseConfirmationDialog.signals.@"disconnect-request".connect(
                dialog,
                *adw.TabPage,
                closeConfirmationDisconnectTab,
                page,
                .{},
            );
        }
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCloseTab,
            page,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCancelTab,
            page,
            .{},
        );

        // Show it
        dialog.present(child);
        return @intFromBool(true);
    }

    fn tabViewSelectedPage(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Get our current page which MUST be a Tab object.
        const page = priv.tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));

        // The title follows the selected tab - unless a script pinned the
        // window's title (T3370), which wins until it is cleared - with the
        // activity suffix (T3561).
        self.syncTitle();

        // If the tab was previously marked as needing attention
        // (e.g. due to a bell character), we now unmark that
        page.setNeedsAttention(@intFromBool(false));

        // The sidebar lists the selected tab's panes (T3557).
        self.queueSidebarRefresh();
    }

    fn tabViewPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // Get the attached page which must be a Tab object.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;

        // Attach listeners for the tab.
        _ = Tab.signals.@"close-request".connect(
            tab,
            *Self,
            tabCloseRequest,
            self,
            .{},
        );

        // Attach listeners for the surface.
        //
        // Interesting behavior here that was previously undocumented but
        // I'm going to make it explicit here: we accept all the signals here
        // (like toggle-fullscreen) regardless of whether the surface or tab
        // is focused. At the time of writing this we have no API that could
        // really trigger these that way but its theoretically possible.
        //
        // What is DEFINITELY possible is something like OSC52 triggering
        // a clipboard-write signal on an unfocused tab/surface. We definitely
        // want to show the user a notification about that but our notification
        // right now is a toast that doesn't make it clear WHO used the
        // clipboard. We probably want to change that in the future.
        //
        // I'm not sure how desirable all the above is, and we probably
        // should be thoughtful about future signals here. But all of this
        // behavior is consistent with macOS and the previous GTK apprt,
        // but that behavior was all implicit and not documented, so here
        // I am.
        if (tab.getSurfaceTree()) |tree| {
            self.connectSurfaceHandlers(tree);
        }

        // The focused pane is the sidebar's selected row (T3557).
        // Disconnected with the tab's other handlers on detach (by data).
        _ = gobject.Object.signals.notify.connect(tab, *Self, sidebarTabNotify, self, .{ .detail = "active-surface" });

        // A tab more: a window's lone pane may pop out now (T3618).
        self.syncPopOut();
        // The window's title is the selected tab's plus the activity suffix
        // (T3561), recomposed whenever that title moves.
        _ = gobject.Object.signals.notify.connect(tab, *Self, tabTitleNotify, self, .{ .detail = "title" });
        self.queueSidebarRefresh();
        // The tab brings its panes' states (a tab moved in from another
        // window keeps them).
        self.syncActivity();
    }

    fn tabTitleNotify(tab: *Tab, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const page = self.private().tab_view.getSelectedPage() orelse return;
        if (page.getChild() != tab.as(gtk.Widget)) return;
        self.syncTitle();
    }

    // ---- Activity state (T3561) --------------------------------------------

    /// The most urgent activity state across every pane in every tab
    /// (`needs_input` > `busy` > `idle`), as Mac and win32 aggregate it.
    pub fn activityAggregate(self: *Self) window_activity.State {
        var agg: window_activity.State = .idle;
        const view = self.private().tab_view;
        const n: c_int = view.getNPages();
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const tab = gobject.ext.cast(Tab, view.getNthPage(i).getChild()) orelse continue;
            agg = window_activity.worse(agg, tab.activityAggregate());
        }
        return agg;
    }

    /// A pane's activity state moved, or the panes did (a split closed, a
    /// tab came or went): mark each tab on the tab bar and recompose the
    /// window title. Cheap - a walk of this window's panes.
    pub fn syncActivity(self: *Self) void {
        const view = self.private().tab_view;
        const n: c_int = view.getNPages();
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = view.getNthPage(i);
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const now = tab.activityAggregate();
            const old = tab.swapActivity(now);
            const marks = window_activity.tabMarks(old, now);
            page.setLoading(@intFromBool(marks.loading));
            if (marks.attention) |a| page.setNeedsAttention(@intFromBool(a));
            if (old != now) log.info("activity: tab={d} state={s} loading={} attention={?}", .{
                i, @tagName(now), marks.loading, marks.attention,
            });
        }
        // State never pauses (T3654): a parked workspace still asks for
        // attention, and the shared window rolls every workspace up.
        self.noteActivityAttention(self.activityAggregate());
        if (Workspaces.manages(self)) Workspaces.refreshActivity();
        self.syncTitle();
    }

    /// Ask for attention when this window's aggregate moves INTO
    /// `needs_input` while the window the person sees is in the background
    /// (Mac `setupActivityStatePublisher` -> `requestUserAttention`, win32
    /// T2907's taskbar flash; here the urgency the bell's `attention` feature
    /// sets, cleared when that window is activated). A parked workspace asks
    /// on the shared toplevel (T3654): on Mac its window is nil, so never
    /// key. Logs every move into or out of `needs_input`.
    fn noteActivityAttention(self: *Self, aggregate: window_activity.State) void {
        const priv = self.private();
        const needs_input = aggregate == .needs_input;
        if (needs_input == priv.activity_attention.needs_input) return;
        const target = Workspaces.attentionWindow(self);
        const active = if (target) |t| t.as(gtk.Window).isActive() != 0 else false;
        const urgent = priv.activity_attention.observe(needs_input, active) and target != null;
        if (urgent) target.?.winproto().setUrgent(true) catch |err| {
            log.warn("winproto failed to set urgency={}", .{err});
        };
        log.info("activity attention needs_input={} active={} urgent={} parked={} target={s}", .{
            needs_input,
            active,
            urgent,
            Workspaces.isParked(self),
            if (target) |t| (t.ipcName() orelse "?") else "none",
        });
    }

    /// Set the window title: the pinned title (T3370), else the selected
    /// tab's, then the activity suffix (" (busy)", " (question)").
    pub fn syncTitle(self: *Self) void {
        const priv = self.private();
        const base: ?[]const u8 = priv.title_override orelse blk: {
            const page = priv.tab_view.getSelectedPage() orelse break :blk null;
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse break :blk null;
            break :blk tab.getTitle();
        };
        const alloc = Application.default().allocator();
        const title = (window_activity.composeTitle(alloc, base, self.activityAggregate()) catch return) orelse return;
        const current: ?[*:0]const u8 = self.as(gtk.Window).getTitle();
        if (current) |c| {
            if (std.mem.eql(u8, std.mem.span(c), title)) {
                // Back to what the window already shows: nothing is held.
                alloc.free(title);
                self.dropHeldTitle();
                return;
            }
        }

        // T3571: a hidden window holds a changing title (a spinner in a
        // program's title would otherwise be a compositor round trip ten
        // times a second for nobody) and lands it when it shows, or after
        // `held_title_interval_ms` so the window list is never far behind.
        switch (window_seen.titleAction(priv.seen, priv.title_landed_ms, nowMs())) {
            .land => {
                defer alloc.free(title);
                self.landTitle(title);
            },
            .hold => |ms| {
                if (priv.held_title) |v| alloc.free(v);
                priv.held_title = title;
                if (priv.held_title_timer == 0) {
                    priv.held_title_timer = glib.timeoutAdd(@intCast(@max(ms, 1)), heldTitleTimer, self);
                }
            },
        }
    }

    /// The window's title as it is now, held or landed: what `+list` and the
    /// pane sidebar read, so a reader that does not look at the screen never
    /// sees a held title late (T3571).
    pub fn currentTitle(self: *Self) ?[*:0]const u8 {
        if (self.private().held_title) |t| return t.ptr;
        return self.as(gtk.Window).getTitle();
    }

    fn landTitle(self: *Self, title: [:0]const u8) void {
        const priv = self.private();
        self.dropHeldTitle();
        // T3648: the shared toplevel's own workspace, parked, must not title
        // the window another workspace is on show in: its title stays held
        // (what `+list` reads) until it is on show again.
        if (Workspaces.physical() == self and Workspaces.isParked(self)) {
            priv.held_title = Application.default().allocator().dupeZ(u8, title) catch null;
            return;
        }
        self.as(gtk.Window).setTitle(title);
        // T3648: the workspace on show titles the shared toplevel too.
        if (Workspaces.active() == self) if (Workspaces.physical()) |t| {
            if (t != self) t.as(gtk.Window).setTitle(title);
        };
        priv.title_landed_ms = nowMs();
    }

    fn dropHeldTitle(self: *Self) void {
        const priv = self.private();
        if (priv.held_title_timer != 0) {
            _ = glib.Source.remove(priv.held_title_timer);
            priv.held_title_timer = 0;
        }
        if (priv.held_title) |v| Application.default().allocator().free(v);
        priv.held_title = null;
    }

    /// Land a held title, if any (the window showed, or the interval ran).
    fn landHeldTitle(self: *Self) void {
        const priv = self.private();
        const held = priv.held_title orelse return;
        priv.held_title = null;
        defer Application.default().allocator().free(held);
        self.landTitle(held);
    }

    fn heldTitleTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        // The source is finished once this returns 0; forget its id first so
        // `landTitle` does not remove it a second time.
        self.private().held_title_timer = 0;
        self.landHeldTitle();
        return 0;
    }

    fn nowMs() i64 {
        return @divTrunc(glib.getMonotonicTime(), std.time.us_per_ms);
    }

    /// The compositor's toplevel state bits that decide whether this window
    /// is seen, or the Debug seam's stand-in for them.
    pub fn toplevelState(self: *Self) window_seen.Toplevel {
        if (self.private().toplevel_override) |o| return o;
        return self.reportedToplevelState();
    }

    /// What the compositor itself reports, whatever the Debug seam set.
    pub fn reportedToplevelState(self: *Self) window_seen.Toplevel {
        const surface = self.as(gtk.Native).getSurface() orelse return .{};
        const toplevel = gobject.ext.cast(gdk.Toplevel, surface) orelse return .{};
        const state = toplevel.getState();
        return .{ .minimized = state.minimized, .suspended = state.suspended };
    }

    /// Whether this window can be seen (T3571), as last computed.
    pub fn isSeen(self: *Self) bool {
        return self.private().seen;
    }

    /// The title a hidden window is holding, or null (the Debug seam).
    pub fn heldTitle(self: *Self) ?[]const u8 {
        return self.private().held_title;
    }

    /// Whether the Debug seam stands in for the toplevel state.
    pub fn hasToplevelOverride(self: *Self) bool {
        return self.private().toplevel_override != null;
    }

    /// Debug seam: stand in for the compositor's toplevel state, or null to
    /// read the real one again.
    pub fn setToplevelOverride(self: *Self, state: ?window_seen.Toplevel) void {
        self.private().toplevel_override = state;
        self.syncSeen();
    }

    /// Recompute whether the window can be seen and, when that changed, tell
    /// every pane in it and land any held title (T3571).
    pub fn syncSeen(self: *Self) void {
        const priv = self.private();
        // T3648: a workspace is seen through the shared toplevel while on
        // show, and never while parked (parked counts as hidden).
        const through = Workspaces.seenThrough(self);
        const mapped = if (through) |w| w.as(gtk.Widget).getMapped() != 0 else false;
        const state = if (through) |w| w.toplevelState() else window_seen.Toplevel{};
        const now = window_seen.windowSeen(mapped, state);
        if (now == priv.seen) return;
        priv.seen = now;
        log.info("seen: window={s} seen={} mapped={} minimized={} suspended={}", .{
            self.ipcName() orelse "?", now, mapped, state.minimized, state.suspended,
        });
        self.syncPanesSeen();
        if (now) self.landHeldTitle();
    }

    /// Tell every pane in every tab whether it can be seen now.
    fn syncPanesSeen(self: *Self) void {
        const tab_view = self.private().tab_view;
        const n: usize = @intCast(tab_view.getNPages());
        for (0..n) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const tree = tab.getSurfaceTree() orelse continue;
            var it = tree.iterator();
            while (it.next()) |entry| entry.view.syncSeen();
        }
    }

    fn propGdkToplevelState(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncSeen();
        Workspaces.toplevelSeenChanged(self);
    }

    fn windowMapChanged(_: *gtk.Widget, self: *Self) callconv(.c) void {
        self.syncSeen();
        Workspaces.toplevelSeenChanged(self);
    }

    // ---- Single-window mode (T3648) ---------------------------------------

    /// This workspace's content: the template's root, the `Adw.TabOverview`
    /// holding the header bar, tab bar, sidebar and tabs.
    pub fn contentRoot(self: *Self) *gtk.Widget {
        return self.private().tab_overview.as(gtk.Widget);
    }

    /// The workspace's `win` actions on its content root, so menus,
    /// accelerators and the palette reach it inside the shared toplevel
    /// (whose own `win` group is the toplevel's own workspace's).
    pub fn adoptWinActionsOnContent(self: *Self) void {
        self.contentRoot().insertActionGroup("win", self.as(gio.ActionGroup));
    }

    /// Take this workspace's content out of whichever window holds it (its
    /// own or the shared toplevel), kept whole by this workspace's own
    /// reference: it is parked. No-op while already held.
    pub fn holdContent(self: *Self) void {
        const priv = self.private();
        if (priv.held_content != null) return;
        const root = self.contentRoot();
        _ = root.as(gobject.Object).ref();
        priv.held_content = root;
        if (root.getRoot()) |r| {
            if (gobject.ext.cast(adw.ApplicationWindow, r)) |holder| {
                if (holder.getContent() == root) holder.setContent(null);
            }
        }
        if (root.getParent() != null) root.unparent();
    }

    /// `holdContent` from the toplevel `from` (the same act; named for the
    /// hand-off's reading).
    pub fn holdContentFrom(self: *Self, from: *Self) void {
        _ = from;
        self.holdContent();
    }

    /// Put this workspace's held content back into its own window.
    pub fn releaseContent(self: *Self) void {
        self.releaseContentInto(self);
    }

    /// Put this workspace's held content into `into` (its own window, or
    /// the shared toplevel), dropping the hold. No-op when not held.
    pub fn releaseContentInto(self: *Self, into: *Self) void {
        const priv = self.private();
        const root = priv.held_content orelse return;
        priv.held_content = null;
        into.as(adw.ApplicationWindow).setContent(root);
        root.as(gobject.Object).unref();
    }

    /// The workspace is gone (its GtkWindow released by the application, or
    /// disposed): out of the host, every content back in a window of its
    /// own, and the content root's `win` group - which references this
    /// Window, a cycle through its own content - dropped. Idempotent.
    pub fn leaveWorkspace(self: *Self) void {
        if (!Workspaces.manages(self) and self.private().held_content == null) return;
        Workspaces.forget(self);
        self.releaseContent();
        self.contentRoot().insertActionGroup("win", null);
    }

    /// "Go to this window" (Mac `bringForward`, T3649): a sidebar click,
    /// `--focus`, a pane's present request, goto_window. In single-window
    /// mode it puts this workspace on show in the shared toplevel (admitting
    /// a window built outside `initAndShowWindow` - a tab or pane dragged
    /// out - as a new workspace first); otherwise it presents this window.
    pub fn bringForward(self: *Self) void {
        if (Workspaces.applies(self)) {
            if (!Workspaces.manages(self)) {
                if (Workspaces.present(self, true)) return;
            } else if (Workspaces.show(self, true)) return;
        }
        self.as(gtk.Window).present();
    }

    /// Whether this workspace's content is held out of every window.
    pub fn isContentHeld(self: *Self) bool {
        return self.private().held_content != null;
    }

    fn tabViewPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // We need to get the tab to disconnect the signals.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        _ = gobject.signalHandlersDisconnectMatched(
            tab.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        // Remove the tree handlers
        if (tab.getSurfaceTree()) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        // Its panes' states leave with it (T3561).
        self.syncActivity();

        // A tab fewer: a window's last pane may no longer pop out (T3618).
        self.syncPopOut();
    }

    fn tabViewCreateWindow(
        _: *adw.TabView,
        _: *Self,
    ) callconv(.c) *adw.TabView {
        // Create a new window without creating a new tab.
        const win = gobject.ext.newInstance(
            Self,
            .{
                .application = Application.default(),
            },
        );

        // We have to show it otherwise it'll just be hidden. In
        // single-window mode a tab dragged out is a new workspace, on show
        // (T3649).
        win.bringForward();

        // Get our tab view
        return win.private().tab_view;
    }

    fn tabCloseRequest(
        tab: *Tab,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.tab_view.getPage(tab.as(gtk.Widget));
        // TODO: connect close page handler to tab to check for confirmation
        priv.tab_view.closePage(page);
    }

    fn tabViewNPages(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.tab_view.getNPages() == 0) {
            // If we have no pages left then we want to close window.

            // If the tab overview is open, then we don't close the window
            // because its a rather abrupt experience. This also fixes an
            // issue where dragging out the last tab in the tab overview
            // won't cause Ghostty to exit.
            if (priv.tab_overview.getOpen() != 0) return;

            // T3652: a frame's tabs were closed on purpose; it stays.
            if (priv.frame_only) return;

            // Its OWN close, never routed: in single-window mode the shared
            // toplevel's close button closes the workspace on show, but a
            // parked toplevel workspace whose last pane went closes itself.
            self.requestClose();
        }
    }
    fn setupTabMenu(
        _: *adw.TabView,
        page: ?*adw.TabPage,
        self: *Self,
    ) callconv(.c) void {
        self.private().context_menu_page = page;
    }

    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        // We only toast for the standard clipboard.
        if (clipboard_type != .standard) return;

        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }

        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }

    fn surfaceMenu(
        _: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.syncActions();
    }

    fn surfacePresentRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        // Verify that this surface is actually in this window.
        {
            const surface_window = ext.getAncestor(
                Self,
                surface.as(gtk.Widget),
            ) orelse {
                log.warn(
                    "present request called for non-existent surface",
                    .{},
                );
                return;
            };
            if (surface_window != self) {
                log.warn(
                    "present request called for surface in different window",
                    .{},
                );
                return;
            }
        }

        // Get the tab for this surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse {
            log.warn("present request surface not found", .{});
            return;
        };

        // Get the page that contains this tab
        const priv = self.private();
        const tab_view = priv.tab_view;
        const page = tab_view.getPage(tab.as(gtk.Widget));
        tab_view.setSelectedPage(page);

        // Bring the window to the front - in single-window mode, its
        // workspace on show (T3649) - then focus the pane, which a parked
        // workspace's pane could not take out of every window.
        self.bringForward();
        surface.grabFocus();
    }

    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }

        // We react to the changes in the propFullscreen callback
    }

    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }

        // We react to the changes in the propMaximized callback
    }

    fn surfaceInit(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Make sure we init only once
        if (priv.surface_init) return;
        priv.surface_init = true;

        // Setup our default and minimum size.
        if (surface.getDefaultSize()) |size| {
            self.as(gtk.Window).setDefaultSize(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
        if (surface.getMinSize()) |size| {
            self.as(gtk.Widget).setSizeRequest(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
    }

    fn tabSplitTreeChanged(
        _: *SplitTree,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        if (old_tree) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        if (new_tree) |tree| {
            self.connectSurfaceHandlers(tree);
        }
        self.queueSidebarRefresh();
        // A closed busy pane takes its state with it (T3561).
        self.syncActivity();
        // T3650: a parked workspace's content is laid out at once.
        Workspaces.treeChanged(self);
    }

    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = "Ghostty";
        const icon = "com.dzearing.ghoztty";
        const website = "https://ghostty.org";

        if (adw_version.supportsDialogs()) {
            adw.showAboutDialog(
                self.as(gtk.Widget),
                "application-name",
                name,
                "developer-name",
                i18n._("Ghostty Developers"),
                "application-icon",
                icon,
                "version",
                build_config.version_string.ptr,
                "issue-url",
                "https://github.com/ghostty-org/ghostty/issues",
                "website",
                website,
                @as(?*anyopaque, null),
            );
        } else {
            gtk.showAboutDialog(
                self.as(gtk.Window),
                "program-name",
                name,
                "logo-icon-name",
                icon,
                "title",
                i18n._("About Ghostty"),
                "version",
                build_config.version_string.ptr,
                "website",
                website,
                @as(?*anyopaque, null),
            );
        }
    }

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        // T3652: the `win` group a key or menu reached is the workspace's
        // own, so this closes this workspace, on show or parked.
        self.requestClose();
    }

    fn actionCloseTab(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("win.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const mode = std.meta.stringToEnum(
            input.Binding.Action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to win.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            log.warn("invalid mode provided to win.close-tab: {s}", .{str.?});
            return;
        };

        self.performBindingAction(.{ .close_tab = mode });
    }

    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }

    fn actionNewTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn actionPromptContextTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.context_menu_page orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        tab.promptTabTitle();
    }

    fn actionPromptSurfaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_surface_title);
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_tab_title);
    }

    fn actionSplitRight(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }

    fn actionSplitLeft(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }

    fn actionSplitUp(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }

    fn actionSplitDown(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .down });
    }

    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }

    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;

        if (config.@"bell-features".system) system: {
            const native = self.as(gtk.Native).getSurface() orelse {
                log.warn("unable to get native surface from window", .{});
                break :system;
            };
            native.beep();
        }

        if (config.@"bell-features".attention) attention: {
            // Dont set urgency if the window is already active.
            if (self.as(gtk.Window).isActive() != 0) break :attention;

            // Request user attention
            self.winproto().setUrgent(true) catch |err| {
                log.warn("winproto failed to set urgency={}", .{err});
            };
        }
    }

    /// Toggle the command palette.
    ///
    /// TODO: accept the surface that toggled the command palette as a parameter
    fn toggleCommandPalette(self: *Window) void {
        const priv = self.private();

        // Get a reference to a command palette. First check the weak reference
        // that we save to see if we already have one stored. If we don't then
        // create a new one.
        const command_palette = priv.command_palette.get() orelse command_palette: {
            // Create a fresh command palette.
            const command_palette = CommandPalette.new();

            // Synchronize our config to the command palette's config.
            _ = gobject.Object.bindProperty(
                self.as(gobject.Object),
                "config",
                command_palette.as(gobject.Object),
                "config",
                .{ .sync_create = true },
            );

            // Listen to the activate signal to know if the user selected an option in
            // the command palette.
            _ = CommandPalette.signals.trigger.connect(
                command_palette,
                *Window,
                signalCommandPaletteTrigger,
                self,
                .{},
            );

            // Save a weak reference to the command palette. We use a weak reference to avoid
            // reference counting cycles that might cause problems later.
            priv.command_palette.set(command_palette);

            break :command_palette command_palette;
        };
        defer command_palette.unref();

        // Tell the command palette to toggle itself. If the dialog gets
        // presented (instead of hidden) it will be modal over our window.
        command_palette.toggle(self);
    }

    /// Debug-only seam hook (T3640): this window's command palette, or null
    /// when none was ever opened (or it was freed). The caller owns a ref.
    pub fn seamCommandPalette(self: *Window) ?*CommandPalette {
        return self.private().command_palette.get();
    }

    /// Debug-only seam hook (T3640): the main menu's model, as its two menu
    /// buttons show it (the `main_menu` object of window.blp).
    pub fn seamMainMenu(self: *Window) *gio.MenuModel {
        return self.private().main_menu.as(gio.MenuModel);
    }

    // React to a signal from a command palette asking an action to be performed.
    fn signalCommandPaletteTrigger(_: *CommandPalette, action: *const input.Binding.Action, self: *Self) callconv(.c) void {
        // If the activation actually has an action, perform it.
        self.performBindingAction(action.*);
    }

    /// React to a GTK action requesting that the command palette be toggled.
    fn actionToggleCommandPalette(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleCommandPalette();
    }

    /// Toggle the Ghostty inspector for the active surface.
    fn toggleInspector(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        _ = surface.controlInspector(.toggle);
    }

    /// React to a GTK action requesting that the Ghostty inspector be toggled.
    fn actionToggleInspector(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleInspector();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(Tab);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"quick-terminal".impl,
                properties.@"tabs-autohide".impl,
                properties.@"tabs-visible".impl,
                properties.@"tabs-wide".impl,
                properties.@"toolbar-style".impl,
                properties.@"titlebar-style".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tab_overview", .{});
            class.bindTemplateChildPrivate("tab_bar", .{});
            class.bindTemplateChildPrivate("tab_view", .{});
            class.bindTemplateChildPrivate("toolbar", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateChildPrivate("sidebar_row", .{});
            class.bindTemplateChildPrivate("main_menu", .{});

            // Template Callbacks
            class.bindTemplateCallback("realize", &windowRealize);
            class.bindTemplateCallback("new_tab", &btnNewTab);
            class.bindTemplateCallback("overview_create_tab", &tabOverviewCreateTab);
            class.bindTemplateCallback("overview_notify_open", &tabOverviewOpen);
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("close_page", &tabViewClosePage);
            class.bindTemplateCallback("page_attached", &tabViewPageAttached);
            class.bindTemplateCallback("page_detached", &tabViewPageDetached);
            class.bindTemplateCallback("setup_tab_menu", &setupTabMenu);
            class.bindTemplateCallback("tab_create_window", &tabViewCreateWindow);
            class.bindTemplateCallback("notify_n_pages", &tabViewNPages);
            class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_is_active", &propIsActive);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_quick_terminal", &propQuickTerminal);
            class.bindTemplateCallback("notify_scale_factor", &propScaleFactor);
            class.bindTemplateCallback("titlebar_style_is_tabs", &closureTitlebarStyleIsTab);
            class.bindTemplateCallback("computed_subtitle", &closureSubtitle);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            // The desk behind the whole content (T3623).
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
