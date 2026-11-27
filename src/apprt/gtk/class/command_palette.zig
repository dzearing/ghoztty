const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const Config = @import("config.zig").Config;
const AgentUpgrade = @import("../AgentUpgrade.zig");
const agent_upgrade = @import("../../win32/agent_upgrade.zig");
const agent_upgrade_rules = @import("../agent_upgrade_rules.zig");
const shell_pick = @import("../shell_pick.zig");
const SettingsWindow = @import("../SettingsWindow.zig");
const wk = @import("../webkit.zig");

const log = std.log.scoped(.gtk_ghostty_command_palette);

pub const CommandPalette = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommandPalette",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
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
    };

    pub const signals = struct {
        /// Emitted when a command from the command palette is activated. The
        /// action contains pointers to allocated data so if a receiver of this
        /// signal needs to keep the action around it will need to clone the
        /// action or there may be use-after-free errors.
        pub const trigger = struct {
            pub const name = "trigger";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{*const input.Binding.Action},
                void,
            );
        };

        /// Emitted when a shell is picked from a "... with Shell" row's list
        /// (T3737): open `target` (a `shell_pick.Target`) on the shell at
        /// `path`. The palette has already closed.
        pub const shell_picked = struct {
            pub const name = "shell-picked";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ c_int, [*:0]const u8 },
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this command palette is using.
        config: ?*Config = null,

        /// The dialog object containing the palette UI.
        dialog: *adw.Dialog,

        /// The search input text field.
        search: *gtk.SearchEntry,

        /// The view containing each result row.
        view: *gtk.ListView,

        /// The model that provides filtered data for the view to display.
        model: *gtk.SingleSelection,

        /// The list that serves as the data source of the model.
        /// This is where all command data is ultimately stored.
        source: *gio.ListStore,

        /// While a "... with Shell" row's second step is up (T3737): what the
        /// picked shell opens. Null: the command list.
        shell_target: ?shell_pick.Target = null,

        /// Whether the window the palette opened over runs its panes on
        /// THIS machine. The shell list is this machine's shells, so the
        /// "... with Shell" rows are hidden in a remote machine's window
        /// (win32 `Condition.local_window`).
        local_window: bool = true,

        pub var offset: c_int = 0;
    };

    /// Create a new instance of the command palette. The caller will own a
    /// reference to the object.
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});

        // Sink ourselves so that we aren't floating anymore. We'll unref
        // ourselves when the palette is closed or an action is activated.
        _ = self.refSink();

        // Bump the ref so that the caller has a reference.
        return self.ref();
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Listen for any changes to our config.
        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            propConfig,
            null,
            .{
                .detail = "config",
            },
        );
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.source.removeAll();

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
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

    //---------------------------------------------------------------
    // Signal Handlers

    fn propConfig(self: *CommandPalette, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
        self.rebuild();
    }

    /// Refill the list from the config, the open surfaces, and the app state
    /// rows (T3691). Run when the config changes and each time the palette
    /// opens, so a row that depends on state (the waiting background update)
    /// is current when the user looks.
    fn rebuild(self: *CommandPalette) void {
        const priv = self.private();

        const config = priv.config orelse {
            log.warn("command palette does not have a config!", .{});
            return;
        };

        // Clear existing binds
        priv.source.removeAll();

        const alloc = Application.default().allocator();
        var commands: std.ArrayList(*Command) = .{};
        defer {
            for (commands.items) |cmd| cmd.unref();
            commands.deinit(alloc);
        }

        // The second step of a "... with Shell" row (T3737): the installed
        // shells, in the Settings > Shell order, and nothing else.
        if (priv.shell_target != null) {
            collectShellChoices(config, &commands, alloc);
            for (commands.items) |cmd| priv.source.append(cmd.as(gobject.Object));
            return;
        }

        self.collectJumpCommands(config, &commands) catch |err| {
            log.warn("failed to collect jump commands: {}", .{err});
        };

        self.collectRegularCommands(config, &commands, alloc);
        collectStateCommands(config, &commands, alloc);
        if (priv.local_window) collectWithShellCommands(config, &commands, alloc);

        // Sort commands
        std.mem.sort(*Command, commands.items, {}, struct {
            fn lessThan(_: void, a: *Command, b: *Command) bool {
                return compareCommands(a, b);
            }
        }.lessThan);

        for (commands.items) |cmd| {
            const cmd_ref = cmd.as(gobject.Object);
            priv.source.append(cmd_ref);
        }
    }

    /// Collect regular commands from configuration, filtering out unsupported actions.
    fn collectRegularCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
        alloc: std.mem.Allocator,
    ) void {
        _ = self;
        const cfg = config.get();

        for (cfg.@"command-palette-entry".value.items) |command| {
            // Filter out actions that are not implemented or don't make sense
            // for GTK.
            if (!isActionSupportedOnGtk(command.action)) continue;

            const cmd = Command.new(config, command) catch |err| {
                log.warn("failed to create command: {}", .{err});
                continue;
            };
            errdefer cmd.unref();

            commands.append(alloc, cmd) catch |err| {
                log.warn("failed to add command to list: {}", .{err});
                continue;
            };
        }
    }

    /// Rows that exist only while some app state holds (T3691): today the
    /// waiting background-process update (win32's `install_agent_update`,
    /// listed only while `agent_update_pending`).
    fn collectStateCommands(config: *Config, commands: *std.ArrayList(*Command), alloc: Allocator) void {
        if (AgentUpgrade.pendingUpdate(Application.default()) == null) return;
        const cmd = Command.newAppAction(
            config,
            agent_upgrade.pending_palette_name,
            "A newer background process is waiting for your sessions to close",
            agent_upgrade_rules.install_action_detailed,
        );
        commands.append(alloc, cmd) catch |err| {
            cmd.unref();
            log.warn("failed to add command to list: {}", .{err});
        };
    }

    /// The four "... with Shell" rows (T3737), in a local window only.
    fn collectWithShellCommands(config: *Config, commands: *std.ArrayList(*Command), alloc: Allocator) void {
        for (std.enums.values(shell_pick.Target)) |target| {
            const cmd = Command.newWithShell(config, target);
            commands.append(alloc, cmd) catch |err| {
                cmd.unref();
                log.warn("failed to add command to list: {}", .{err});
            };
        }
    }

    /// The shell list a "... with Shell" row swaps in (T3737): one row per
    /// installed shell, titled by its name with its path below.
    fn collectShellChoices(config: *Config, commands: *std.ArrayList(*Command), alloc: Allocator) void {
        var arena_state = ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const shells = SettingsWindow.installedShells(arena_state.allocator()) catch |err| {
            log.warn("failed to list the installed shells: {}", .{err});
            return;
        };
        if (shells.len == 0) log.info("command palette: no installed shell found on PATH", .{});
        for (shells) |sh| {
            const cmd = Command.newShell(config, sh) catch |err| {
                log.warn("failed to create shell row: {}", .{err});
                continue;
            };
            commands.append(alloc, cmd) catch |err| {
                cmd.unref();
                log.warn("failed to add command to list: {}", .{err});
            };
        }
    }

    /// Check if an action is supported on GTK.
    fn isActionSupportedOnGtk(action: input.Binding.Action) bool {
        return switch (action) {
            .close_all_windows,
            .toggle_secure_input,
            .check_for_updates,
            .redo,
            .undo,
            .reset_window_size,
            .toggle_window_float_on_top,
            => false,

            else => true,
        };
    }

    /// Collect jump commands for all surfaces across all windows.
    fn collectJumpCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
    ) !void {
        _ = self;
        const app = Application.default();
        const alloc = app.allocator();

        // Get all surfaces from the core app
        const core_app = app.core();
        for (core_app.surfaces.items) |apprt_surface| {
            const surface = apprt_surface.gobj();
            const cmd = Command.newJump(config, surface);
            errdefer cmd.unref();
            try commands.append(alloc, cmd);
        }
    }

    /// Compare two commands for sorting.
    /// Sorts alphabetically by title (case-insensitive), with colon normalization
    /// so "Foo:" sorts before "Foo Bar:". Uses sort_key as tie-breaker.
    fn compareCommands(a: *Command, b: *Command) bool {
        const a_title = a.propGetTitle() orelse return false;
        const b_title = b.propGetTitle() orelse return true;

        // Compare case-insensitively with colon normalization
        for (0..@min(a_title.len, b_title.len)) |i| {
            // Get characters, replacing ':' with '\t'
            const a_char = if (a_title[i] == ':') '\t' else a_title[i];
            const b_char = if (b_title[i] == ':') '\t' else b_title[i];

            const a_lower = std.ascii.toLower(a_char);
            const b_lower = std.ascii.toLower(b_char);

            if (a_lower != b_lower) {
                return a_lower < b_lower;
            }
        }

        // If one title is a prefix of the other, shorter one comes first
        if (a_title.len != b_title.len) {
            return a_title.len < b_title.len;
        }

        // Titles are equal - use sort_key as tie-breaker if both are jump commands
        const a_sort_key = switch (a.private().data) {
            .regular, .app_action, .with_shell, .shell => return false,
            .jump => |*ja| ja.sort_key,
        };
        const b_sort_key = switch (b.private().data) {
            .regular, .app_action, .with_shell, .shell => return false,
            .jump => |*jb| jb.sort_key,
        };

        return a_sort_key < b_sort_key;
    }

    fn close(self: *CommandPalette) void {
        const priv = self.private();
        _ = priv.dialog.close();
    }

    fn dialogClosed(_: *adw.Dialog, self: *CommandPalette) callconv(.c) void {
        self.unref();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // ESC was pressed. In a "... with Shell" row's shell list it goes
        // back to the commands (T3737, win32's Escape); otherwise it closes.
        if (self.private().shell_target != null) {
            self.setShellStep(null);
            return;
        }
        self.close();
    }

    /// Enter (`target` set) or leave (null) a "... with Shell" row's second
    /// step: the search is cleared, its cue says what a pick opens, and the
    /// list is rebuilt for the step.
    fn setShellStep(self: *CommandPalette, target: ?shell_pick.Target) void {
        const priv = self.private();
        priv.shell_target = target;
        priv.search.as(gtk.Editable).setText("");
        wk.gtk_search_entry_set_placeholder_text(
            @ptrCast(priv.search),
            if (target) |t| t.prompt().ptr else shell_pick.commands_prompt.ptr,
        );
        self.rebuild();
        priv.model.setSelected(0);
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // If Enter is pressed, activate the selected entry
        const priv = self.private();
        self.activated(priv.model.getSelected());
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *CommandPalette) callconv(.c) void {
        self.activated(pos);
    }

    //---------------------------------------------------------------

    /// Show or hide the command palette dialog. If the dialog is shown it will
    /// be modal over the given window.
    pub fn toggle(self: *CommandPalette, window: *Window) void {
        const priv = self.private();

        // If the dialog has been shown, close it.
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        // Every open starts on the command list (T3737), and the "... with
        // Shell" rows exist only over a window on this machine.
        priv.local_window = !window.isRemoteWindow();
        if (priv.shell_target != null) {
            priv.shell_target = null;
            wk.gtk_search_entry_set_placeholder_text(@ptrCast(priv.search), shell_pick.commands_prompt.ptr);
        }

        // State rows (T3691) are read as the palette opens.
        self.rebuild();

        // Show the dialog
        priv.dialog.present(window.as(gtk.Widget));

        // Focus on the search bar when opening the dialog
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Helper function to send a signal containing the action that should be
    /// performed.
    fn activated(self: *CommandPalette, pos: c_uint) void {
        const priv = self.private();

        // Use priv.model and not priv.source here to use the list of *visible* results
        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |object| object.unref();

        // A "... with Shell" row keeps the palette open and swaps its list
        // for the installed shells (T3737, win32 T3751).
        if (object_) |object| if (gobject.ext.cast(Command, object)) |c| {
            if (c.getWithShell()) |target| {
                self.setShellStep(target);
                return;
            }
        };

        // Close before running the action in order to avoid being replaced by
        // another dialog (such as the change title dialog). If that occurs then
        // the command palette dialog won't be counted as having closed properly
        // and cannot receive focus when reopened.
        self.close();

        const cmd = gobject.ext.cast(Command, object_ orelse return) orelse return;

        // A shell from the second step (T3737): the window opens the target
        // on it. The row (and its path) outlives the synchronous emit.
        if (cmd.getShellPath()) |path| {
            const target = priv.shell_target orelse return;
            priv.shell_target = null;
            signals.shell_picked.impl.emit(self, null, .{ @intFromEnum(target), path.ptr }, null);
            return;
        }

        // An app-state row runs its GAction on the application (T3691).
        if (cmd.getAppAction()) |name| {
            const dot = std.mem.indexOfScalar(u8, name, '.') orelse return;
            var buf: [128]u8 = undefined;
            const bare = std.fmt.bufPrintZ(&buf, "{s}", .{name[dot + 1 ..]}) catch return;
            Application.default().as(gio.ActionGroup).activateAction(bare.ptr, null);
            return;
        }

        // Handle jump commands differently
        if (cmd.isJump()) {
            const surface = cmd.getJumpSurface() orelse return;
            defer surface.unref();
            surface.present();
            return;
        }

        // Regular command - emit trigger signal
        const action = cmd.getAction() orelse return;

        // Signal that an action has been selected. Signals are synchronous
        // so we shouldn't need to worry about cloning the action.
        signals.trigger.impl.emit(
            self,
            null,
            .{&action},
            null,
        );
    }

    //---------------------------------------------------------------
    // Debug-only seam hooks (T3640): the `command-palette` IPC seam
    // (IpcHandlers.commandPaletteSeam) drives the palette through these, the
    // same calls typing in the search field and clicking a row make.

    /// Whether the palette dialog is on screen.
    pub fn seamIsOpen(self: *CommandPalette) bool {
        return self.private().dialog.as(gtk.Widget).getMapped() != 0;
    }

    /// Type `text` into the search field (the filter is bound to it).
    pub fn seamSetQuery(self: *CommandPalette, text: [:0]const u8) void {
        self.private().search.as(gtk.Editable).setText(text);
    }

    /// True while the incremental filter is still working through the list,
    /// so what `seamVisibleAt` reads is not yet the final answer.
    pub fn seamFilterPending(self: *CommandPalette) bool {
        const inner = self.private().model.getModel() orelse return false;
        const filtered = gobject.ext.cast(gtk.FilterListModel, inner) orelse return false;
        return filtered.getPending() != 0;
    }

    /// How many rows the list shows right now.
    pub fn seamVisibleCount(self: *CommandPalette) usize {
        return @intCast(self.private().model.as(gio.ListModel).getNItems());
    }

    /// The title and action key of the shown row at `pos`.
    pub fn seamVisibleAt(self: *CommandPalette, pos: usize) ?struct { title: [:0]const u8, action_key: ?[:0]const u8 } {
        const object = self.private().model.as(gio.ListModel).getObject(@intCast(pos)) orelse return null;
        // The list store keeps its own reference, so the strings outlive this.
        defer object.unref();
        const cmd = gobject.ext.cast(Command, object) orelse return null;
        return .{ .title = cmd.propGetTitle() orelse return null, .action_key = cmd.propGetActionKey() };
    }

    /// Activate the shown row at `pos`: what a click on it does.
    pub fn seamActivate(self: *CommandPalette, pos: usize) void {
        self.activated(@intCast(pos));
    }

    /// Escape in the search field: what `stop-search` does (T3737).
    pub fn seamEscape(self: *CommandPalette) void {
        searchStopped(self.private().search, self);
    }

    /// The "... with Shell" step the palette is on (its `key()`), else null.
    pub fn seamShellStep(self: *CommandPalette) ?[:0]const u8 {
        const t = self.private().shell_target orelse return null;
        return t.key();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(Command);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "command-palette",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("source", .{});

            // Template Callbacks
            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("row_activated", &rowActivated);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Signals
            signals.trigger.impl.register(.{});
            signals.shell_picked.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// Object that wraps around a command.
///
/// As GTK list models only accept objects that are within the GObject hierarchy,
/// we have to construct a wrapper to be easily consumed by the list model.
const Command = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommand",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
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

        pub const action_key = struct {
            pub const name = "action-key";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetActionKey,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const action = struct {
            pub const name = "action";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetAction,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetTitle,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const description = struct {
            pub const name = "description";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetDescription,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    pub const Private = struct {
        config: ?*Config = null,
        arena: ArenaAllocator,
        data: CommandData,

        pub var offset: c_int = 0;

        pub const CommandData = union(enum) {
            regular: RegularData,
            jump: JumpData,
            app_action: AppActionData,
            /// A "... with Shell" row (T3737): choosing it opens the shell
            /// list for this target.
            with_shell: shell_pick.Target,
            /// One installed shell in that list (T3737). Strings live in
            /// the row's arena.
            shell: shell_pick.Shell,
        };

        /// A row that runs an application GAction (T3691). Strings are
        /// static.
        pub const AppActionData = struct {
            title: [:0]const u8,
            description: [:0]const u8,
            /// Detailed name, `app.<name>`; also the row's action key.
            action: [:0]const u8,
        };

        pub const RegularData = struct {
            command: input.Command,
            action: ?[:0]const u8 = null,
            action_key: ?[:0]const u8 = null,
        };

        pub const JumpData = struct {
            surface: WeakRef(Surface) = .empty,
            title: ?[:0]const u8 = null,
            description: ?[:0]const u8 = null,
            sort_key: usize,
        };
    };

    pub fn new(config: *Config, command: input.Command) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });
        errdefer self.unref();

        const priv = self.private();
        const cloned = try command.clone(priv.arena.allocator());

        priv.data = .{
            .regular = .{
                .command = cloned,
            },
        };

        return self;
    }

    /// A row that runs the application action `action` (`app.<name>`) when
    /// chosen (T3691). The strings must be static.
    pub fn newAppAction(config: *Config, title: [:0]const u8, description: [:0]const u8, action: [:0]const u8) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });
        self.private().data = .{ .app_action = .{ .title = title, .description = description, .action = action } };
        return self;
    }

    /// A "... with Shell" row for `target` (T3737).
    pub fn newWithShell(config: *Config, target: shell_pick.Target) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });
        self.private().data = .{ .with_shell = target };
        return self;
    }

    /// One installed shell for the second step (T3737); the strings are
    /// copied into the row.
    pub fn newShell(config: *Config, sh: shell_pick.Shell) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });
        errdefer self.unref();
        const priv = self.private();
        const alloc = priv.arena.allocator();
        priv.data = .{ .shell = .{
            .name = try alloc.dupeZ(u8, sh.name),
            .path = try alloc.dupeZ(u8, sh.path),
        } };
        return self;
    }

    /// The target a "... with Shell" row opens a shell list for, else null.
    pub fn getWithShell(self: *Self) ?shell_pick.Target {
        return switch (self.private().data) {
            .with_shell => |t| t,
            else => null,
        };
    }

    /// The path a shell row runs, else null.
    pub fn getShellPath(self: *Self) ?[:0]const u8 {
        return switch (self.private().data) {
            .shell => |sh| sh.path,
            else => null,
        };
    }

    /// The `app.<name>` action an app-state row runs, else null.
    pub fn getAppAction(self: *Self) ?[:0]const u8 {
        return switch (self.private().data) {
            .app_action => |a| a.action,
            else => null,
        };
    }

    /// Create a new jump command that focuses a specific surface.
    pub fn newJump(config: *Config, surface: *Surface) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });

        const priv = self.private();
        priv.data = .{
            .jump = .{
                // TODO: Replace with surface id whenever Ghostty adds one
                .sort_key = @intFromPtr(surface),
            },
        };
        priv.data.jump.surface.set(surface);

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        // NOTE: we do not watch for changes to the config here as the command
        // palette will destroy and recreate this object if/when the config
        // changes.

        const priv = self.private();
        priv.arena = .init(Application.default().allocator());
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        switch (priv.data) {
            .regular, .app_action, .with_shell, .shell => {},
            .jump => |*j| {
                j.surface.set(null);
            },
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.arena.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------

    fn propGetActionKey(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        const regular = switch (priv.data) {
            .regular => |*r| r,
            .jump => return null,
            .app_action => |a| return a.action,
            .with_shell => |t| return t.key(),
            .shell => |sh| return sh.path,
        };

        if (regular.action_key) |action_key| return action_key;

        regular.action_key = std.fmt.allocPrintSentinel(
            priv.arena.allocator(),
            "{f}",
            .{regular.command.action},
            0,
        ) catch null;

        return regular.action_key;
    }

    fn propGetAction(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        const regular = switch (priv.data) {
            .regular => |*r| r,
            // No keybind: an app-state row has no accelerator to show.
            .jump, .app_action, .with_shell, .shell => return null,
        };

        if (regular.action) |action| return action;

        const cfg = if (priv.config) |config| config.get() else return null;
        const keybinds = cfg.keybind.set;

        const alloc = priv.arena.allocator();

        regular.action = action: {
            var buf: [64]u8 = undefined;
            const trigger = keybinds.getTrigger(regular.command.action) orelse break :action null;
            const accel = (key.accelFromTrigger(&buf, trigger) catch break :action null) orelse break :action null;
            break :action alloc.dupeZ(u8, accel) catch return null;
        };

        return regular.action;
    }

    fn propGetTitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .app_action => |a| return a.title,
            .with_shell => |t| return t.title(),
            .shell => |sh| return sh.name,
            .regular => |*r| return r.command.title,
            .jump => |*j| {
                if (j.title) |title| return title;

                const surface = j.surface.get() orelse return null;
                defer surface.unref();

                const alloc = priv.arena.allocator();
                const effective_title = surface.getEffectiveTitle() orelse "Untitled";

                j.title = std.fmt.allocPrintSentinel(
                    alloc,
                    "Focus: {s}",
                    .{effective_title},
                    0,
                ) catch null;

                return j.title;
            },
        }
    }

    fn propGetDescription(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .app_action => |a| return a.description,
            .with_shell => |t| return t.description(),
            .shell => |sh| return sh.path,
            .regular => |*r| return r.command.description,
            .jump => |*j| {
                if (j.description) |desc| return desc;

                const surface = j.surface.get() orelse return null;
                defer surface.unref();

                const alloc = priv.arena.allocator();
                const title = surface.getEffectiveTitle() orelse "Untitled";
                const pwd = surface.getPwd();

                if (pwd) |p| {
                    if (std.mem.indexOf(u8, title, p) == null) {
                        j.description = alloc.dupeZ(u8, p) catch null;
                    }
                }

                return j.description;
            },
        }
    }

    //---------------------------------------------------------------

    /// Return a copy of the action. Callers must ensure that they do not use
    /// the action beyond the lifetime of this object because it has internally
    /// allocated data that will be freed when this object is.
    pub fn getAction(self: *Self) ?input.Binding.Action {
        const priv = self.private();
        return switch (priv.data) {
            .regular => |*r| r.command.action,
            .jump, .app_action, .with_shell, .shell => null,
        };
    }

    /// Check if this is a jump command.
    pub fn isJump(self: *Self) bool {
        const priv = self.private();
        return priv.data == .jump;
    }

    /// Get the jump surface. Returns a strong reference that the caller
    /// must unref when done, or null if the surface has been destroyed.
    pub fn getJumpSurface(self: *Self) ?*Surface {
        const priv = self.private();
        return switch (priv.data) {
            .regular, .app_action, .with_shell, .shell => null,
            .jump => |*j| j.surface.get(),
        };
    }

    //---------------------------------------------------------------

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
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.action_key.impl,
                properties.action.impl,
                properties.title.impl,
                properties.description.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
