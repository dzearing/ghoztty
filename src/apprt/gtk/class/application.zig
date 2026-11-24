const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const build_info = @import("../build/info.zig");
const state = &@import("../../../global.zig").state;
const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const CoreApp = @import("../../../App.zig");
const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const internal_os = @import("../../../os/main.zig");
const systemd = @import("../../../os/systemd.zig");
const terminal = @import("../../../terminal/main.zig");
const xev = @import("../../../global.zig").xev;
const Binding = @import("../../../input.zig").Binding;
const CoreConfig = configpkg.Config;
const CoreSurface = @import("../../../Surface.zig");
const lib = @import("../../../lib/main.zig");

const ext = @import("../ext.zig");
const key = @import("../key.zig");
const adw_version = @import("../adw_version.zig");
const gtk_version = @import("../gtk_version.zig");
const winprotopkg = @import("../winproto.zig");
const SessionLayout = @import("../SessionLayout.zig");
const PaneSidebar = @import("../PaneSidebar.zig");
const BannerEditor = @import("../BannerEditor.zig");
const AgentRecovery = @import("../AgentRecovery.zig");
const ApprtApp = @import("../App.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Config = @import("config.zig").Config;
const Surface = @import("surface.zig").Surface;
const SplitTree = @import("split_tree.zig").SplitTree;
const Window = @import("window.zig").Window;
const Tab = @import("tab.zig").Tab;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const ConfigErrorsDialog = @import("config_errors_dialog.zig").ConfigErrorsDialog;
const GlobalShortcuts = @import("global_shortcuts.zig").GlobalShortcuts;
const OpenURI = @import("../portal.zig").OpenURI;
const url_scheme = @import("../url_scheme.zig");
const wslg_gpu = @import("../wslg_gpu.zig");
const viewer_chrome = @import("../viewer_chrome.zig");
const CloseUndo = @import("../CloseUndo.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.gtk_ghostty_application);

/// A window size in logical pixels: an adopted popup's requested size (T3447).
pub const WindowSize = struct { w: i32, h: i32 };

/// Function used to funnel GLib/GObject/GTK log messages into Zig's logging
/// system rather than just getting dumped directly to stderr.
fn glibLogWriterFunction(
    level: glib.LogLevelFlags,
    fields: [*]const glib.LogField,
    n_fields: usize,
    _: ?*anyopaque,
) callconv(.c) glib.LogWriterOutput {
    const glib_log = std.log.scoped(.glib);

    var message_: ?[]const u8 = null;
    var domain_: ?[]const u8 = null;
    for (0..n_fields) |i| {
        const field = fields[i];
        const k = std.mem.span(field.f_key orelse continue);
        const v: []const u8 = v: {
            if (field.f_length >= 0) {
                const v: [*]const u8 = @ptrCast(field.f_value orelse continue);
                break :v v[0..@intCast(field.f_length)];
            }
            const v: [*:0]const u8 = @ptrCast(field.f_value orelse continue);
            break :v std.mem.span(v);
        };
        if (std.mem.eql(u8, k, "MESSAGE")) {
            message_ = v;
            continue;
        }
        if (std.mem.eql(u8, k, "GLIB_DOMAIN")) {
            domain_ = v;
            continue;
        }
    }

    const message = message_ orelse return .unhandled;
    const domain = domain_ orelse "«unknown»";

    if (level.level_error) {
        glib_log.err("ERROR: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_critical) {
        glib_log.err("CRITICAL: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_warning) {
        glib_log.warn("WARNING: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_message) {
        glib_log.info("MESSAGE: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_info) {
        glib_log.info("INFO: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_debug) {
        glib_log.debug("DEBUG: {s}: {s}", .{ domain, message });
        return .handled;
    }
    glib_log.debug("UNKNOWN: {s}: {s}", .{ domain, message });
    return .handled;
}

/// The primary entrypoint for the Ghostty GTK application.
///
/// This requires a `ghostty.App` and `ghostty.Config` and takes
/// care of the rest. Call `run` to run the application to completion.
pub const Application = extern struct {
    /// This type creates a new GObject class. Since the Application is
    /// the primary entrypoint I'm going to use this as a place to document
    /// how this all works and where you can find resources for it, but
    /// this applies to any other GObject class within this apprt.
    ///
    /// The various fields (parent_instance) and constants (Parent,
    /// getGObjectType, etc.) are mandatory "interfaces" for zig-gobject
    /// to create a GObject class.
    ///
    /// I found these to be the best resources:
    ///
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/extensions/gobject2.zig
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/example/src/custom_class.zig
    ///
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Application;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyApplication",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                "config",
                Self,
                ?*Config,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Config,
                        .{
                            .getter = Self.getConfig,
                            .getter_transfer = .full,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// The apprt App. This is annoying that we need this it'd be
        /// nicer to just make THIS the apprt app but the current libghostty
        /// API doesn't allow that.
        rt_app: *ApprtApp,

        /// The libghostty App instance.
        core_app: *CoreApp,

        /// The configuration for the application.
        config: *Config,

        /// State and logic for the underlying windowing protocol.
        winproto: winprotopkg.App,

        /// The global shortcut logic.
        global_shortcuts: *GlobalShortcuts,

        /// This is set to true so long as we request a window exactly
        /// once. This prevents quitting the app before we've shown one
        /// window.
        requested_window: bool = false,

        /// This is set to false internally when the event loop
        /// should exit and the application should quit. This must
        /// only be set by the main loop thread.
        running: bool = false,

        /// T3337: set once `quitNow` starts tearing the windows down. A pane
        /// freed while it is set is the app QUITTING, so its agent session
        /// detaches and survives for the next launch; a pane freed while it
        /// is clear was closed by the user, so its session ends (the Mac's
        /// and win32's quit-vs-close rule).
        quitting: bool = false,

        /// The timer used to quit the application after the last window is
        /// closed. Even if there is no quit delay set, this is the state
        /// used to determine to close the app.
        quit_timer: union(enum) {
            off,
            active: c_uint,
            expired,
        } = .off,

        /// If non-null, we're currently showing a config errors dialog.
        /// This is a WeakRef because the dialog can close on its own
        /// outside of our own lifecycle and that's okay.
        config_errors_dialog: WeakRef(ConfigErrorsDialog) = .empty,

        /// glib source for our signal handler.
        signal_source: ?c_uint = null,

        /// CSS Provider for any styles based on Ghostty configuration values.
        css_provider: *gtk.CssProvider,

        /// Providers for loading custom stylesheets defined by user
        custom_css_providers: std.ArrayListUnmanaged(*gtk.CssProvider) = .empty,

        /// A copy of the LANG environment variable that was provided to Ghostty
        /// by the system. If this is null, the LANG environment variable did
        /// not exist in Ghostty's environment variable.
        saved_language: ?[:0]const u8 = null,

        open_uri: OpenURI = undefined,

        pub var offset: c_int = 0;
    };

    /// Get this application as the default, allowing access to its
    /// properties globally.
    ///
    /// This asserts that there is a default application and that the
    /// default application is a GhosttyApplication. The program would have
    /// to be in a very bad state for this to be violated.
    pub fn default() *Self {
        const app = gio.Application.getDefault().?;
        return gobject.ext.cast(Self, app).?;
    }

    /// Creates a new Application instance.
    ///
    /// This does a lot more work than a typical class instantiation,
    /// because we expect that this is the main program entrypoint.
    ///
    /// The only failure mode of initializing the application is early OOM.
    /// Early OOM can't be recovered from. Every other error is mapped to
    /// some degraded state where we can at least show a window with an error.
    pub fn new(
        rt_app: *ApprtApp,
        core_app: *CoreApp,
    ) Allocator.Error!*Self {
        const alloc = core_app.alloc;

        // Capture GLib/GObject/GTK log messages and funnel them through Zig's
        // logging system rather than just getting dumped directly to stderr.
        _ = glib.logSetWriterFunc(glibLogWriterFunction, null, null);

        // Log our GTK versions
        gtk_version.logVersion();
        adw_version.logVersion();

        // Load our configuration.
        var config = CoreConfig.load(alloc) catch |err| err: {
            // If we fail to load the configuration, then we should log
            // the error in the diagnostics so it can be shown to the user.
            // We can still load a default which only fails for OOM, allowing
            // us to startup.
            var def: CoreConfig = try .default(alloc);
            errdefer def.deinit();
            try def.addDiagnosticFmt(
                "error loading user configuration: {}",
                .{err},
            );

            break :err def;
        };
        defer config.deinit();

        const saved_language: ?[:0]const u8 = saved_language: {
            const old_language = old_language: {
                const result = (internal_os.getenv(alloc, "LANG") catch break :old_language null) orelse break :old_language null;
                defer result.deinit(alloc);
                break :old_language alloc.dupeZ(u8, result.value) catch break :old_language null;
            };

            if (config.language) |language| _ = internal_os.setenv("LANG", language);

            break :saved_language old_language;
        };

        // Set gettext global domain to be our app so that our unqualified
        // translations map to our translations.
        internal_os.i18n.initGlobalDomain() catch |err| {
            // Failures shuldn't stop application startup. Our app may
            // not translate correctly but it should still work. In the
            // future we may want to add this to the GUI to show.
            log.warn("i18n initialization failed error={}", .{err});
        };

        // Ghoztty (T3350): under WSLg pick the GPU for our own GL, which Mesa
        // does not do by default. Removed again once GDK's GL is up, below.
        const wslg_gpu_set = setWslgGpuEnv();

        // Setup our GTK init env vars
        setGtkEnv(&config) catch |err| switch (err) {
            error.NoSpaceLeft => {
                // If we fail to set GTK environment variables then we still
                // try to start the application...
                log.warn(
                    "error setting GTK environment variables err={}",
                    .{err},
                );
            },
        };
        adw.init();

        const single_instance = switch (config.@"gtk-single-instance") {
            .true => true,
            .false => false,
            // This should have been resolved to true/false during config loading.
            .detect => unreachable,
        };

        // Setup the flags for our application.
        const app_flags: gio.ApplicationFlags = app_flags: {
            var flags: gio.ApplicationFlags = .flags_default_flags;
            if (!single_instance) flags.non_unique = true;
            // Ghoztty (T3343): the desktop file is DBusActivatable and
            // registers `x-scheme-handler/ghoztty`, so a launcher hands a
            // clicked link to the running app as a D-Bus `Open`, which GLib
            // routes to `open` only with this flag.
            flags.handles_open = true;
            break :app_flags flags;
        };

        // Our app ID determines uniqueness and maps to our desktop file.
        // We append "-debug" to the ID if we're in debug mode so that we
        // can develop Ghostty in Ghostty.
        const app_id: [:0]const u8 = app_id: {
            if (config.class) |class| {
                if (gio.Application.idIsValid(class) != 0) {
                    break :app_id class;
                } else {
                    log.warn("invalid 'class' in config, ignoring", .{});
                }
            }

            break :app_id build_info.application_id;
        };

        const display: *gdk.Display = gdk.Display.getDefault() orelse {
            // I'm unsure of any scenario where this happens. Because we don't
            // want to litter null checks everywhere, we just exit here.
            log.warn("gdk display is null, exiting", .{});
            std.posix.exit(1);
        };
        if (wslg_gpu_set) settleWslgGpuEnv(display);

        // Setup our windowing protocol logic
        var wp: winprotopkg.App = winprotopkg.App.init(
            alloc,
            display,
            app_id,
            &config,
        ) catch |err| wp: {
            // If we fail to detect or setup the windowing protocol
            // specifies, we fallback to a noop implementation so we can
            // still launch.
            log.warn("error initializing windowing protocol err={}", .{err});
            break :wp .{ .none = .{} };
        };
        errdefer wp.deinit();
        log.debug("windowing protocol={s}", .{@tagName(wp)});

        // Create our GTK Application which encapsulates our process.
        log.debug("creating GTK application id={s} single-instance={}", .{
            app_id,
            single_instance,
        });

        // Wrap our configuration in a GObject.
        const config_obj: *Config = try .new(alloc, &config);
        errdefer config_obj.unref();

        // Internally, GTK ensures that only one instance of this provider
        // exists in the provider list for the display.
        const css_provider = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(
            display,
            css_provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 3,
        );
        errdefer css_provider.unref();

        // Initialize the app.
        const self = gobject.ext.newInstance(Self, .{
            .application_id = app_id.ptr,
            .flags = app_flags,

            // Force the resource path to a known value so it doesn't depend
            // on the app id (which changes between debug/release and can be
            // user-configured) and force it to load in compiled resources.
            .resource_base_path = build_info.resource_path,
        });

        // Setup our private state. More setup is done in the init
        // callback that GObject calls, but we can't pass this data through
        // to there (and we don't need it there directly) so this is here.
        const priv: *Private = self.private();
        priv.* = .{
            .rt_app = rt_app,
            .core_app = core_app,
            .config = config_obj,
            .winproto = wp,
            .css_provider = css_provider,
            .custom_css_providers = .empty,
            .global_shortcuts = gobject.ext.newInstance(GlobalShortcuts, .{}),
            .saved_language = saved_language,
            .open_uri = .init(rt_app),
        };

        // Signals
        _ = gobject.Object.signals.notify.connect(
            self,
            *Self,
            propConfig,
            self,
            .{ .detail = "config" },
        );

        _ = gtk.CssProvider.signals.parsing_error.connect(
            css_provider,
            *Self,
            signalCssParsingError,
            self,
            .{},
        );

        // Trigger initial config changes
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        return self;
    }

    /// Force deinitialize the application.
    ///
    /// Normally in a GObject lifecycle, this would be called by the
    /// finalizer. But applications are never fully unreferenced so this
    /// ensures that our memory is cleaned up properly.
    pub fn deinit(self: *Self) void {
        const alloc = self.allocator();
        const priv: *Private = self.private();
        priv.config.unref();
        priv.winproto.deinit();
        priv.open_uri.deinit();
        priv.global_shortcuts.unref();
        if (priv.saved_language) |language| alloc.free(language);
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                priv.css_provider.as(gtk.StyleProvider),
            );

            for (priv.custom_css_providers.items) |provider| {
                gtk.StyleContext.removeProviderForDisplay(
                    display,
                    provider.as(gtk.StyleProvider),
                );
            }
        }
        priv.css_provider.unref();
        for (priv.custom_css_providers.items) |provider| provider.unref();
        priv.custom_css_providers.deinit(alloc);
    }

    /// The global allocator that all other classes should use by
    /// calling `Application.default().allocator()`. Zig code should prefer
    /// this wherever possible so we get leak detection in debug/tests.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.private().core_app.alloc;
    }

    /// Get the original language that Ghostty was launched with. This returns a
    /// pointer to internal memory so it must be copied by callers.
    pub fn savedLanguage(self: *Self) ?[:0]const u8 {
        return self.private().saved_language;
    }

    /// Run the application. This is a replacement for `gio.Application.run`
    /// because we want more tight control over our event loop so we can
    /// integrate it with libghostty.
    pub fn run(self: *Self) !void {
        // Based on the actual `gio.Application.run` implementation:
        // https://github.com/GNOME/glib/blob/a8e8b742e7926e33eb635a8edceac74cf239d6ed/gio/gapplication.c#L2533

        // Acquire the default context for the application
        const ctx = glib.MainContext.default();
        if (glib.MainContext.acquire(ctx) == 0) return error.ContextAcquireFailed;

        // The final cleanup that is always required at the end of running.
        defer {
            // Ensure our timer source is removed
            self.stopQuitTimer();

            // Sync any remaining settings
            gio.Settings.sync();

            // Clear out the event loop, don't block.
            while (glib.MainContext.iteration(ctx, 0) != 0) {}

            // Release the context so something else can use it.
            defer glib.MainContext.release(ctx);
        }

        // Register the application
        var err_: ?*glib.Error = null;
        if (self.as(gio.Application).register(
            null,
            &err_,
        ) == 0) {
            if (err_) |err| {
                defer err.free();
                log.warn(
                    "error registering application: {s}",
                    .{err.f_message orelse "(unknown)"},
                );
            }

            return error.ApplicationRegisterFailed;
        }
        assert(err_ == null);

        // This just calls the `activate` signal but its part of the normal startup
        // routine so we just call it, but only if the config allows it (this allows
        // for launching Ghostty in the "background" without immediately opening
        // a window).
        //
        // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
        const priv = self.private();

        // Ghoztty (T3335): serve the CLI's Unix socket - only as the primary
        // instance (a remote one exits below) and before activation opens
        // the first window, so its pane is baked with the endpoint. Stopped
        // before the final main-context drain above runs.
        if (self.as(gio.Application).getIsRemote() == 0) self.rt().startIpc();
        defer self.rt().stopIpc();

        // Ghoztty (T3397): bring back the windows the last run left, their
        // panes re-attached to the sessions the agent kept. A no-op unless
        // this instance serves the IPC socket with session persistence on.
        const restored: usize = if (self.as(gio.Application).getIsRemote() == 0)
            SessionLayout.restore(self)
        else
            0;

        {
            // We need to scope any config access because once we run our
            // event loop, this can change out from underneath us.
            const config = priv.config.get();
            // A restored launch shows the restored windows, not a fresh one
            // beside them - unless the launch named a command (`-e`), which
            // still opens its own window.
            if (config.@"initial-window" and
                (restored == 0 or config.@"initial-command" != null))
                self.as(gio.Application).activate();
        }

        // From here on the app keeps the manifest current (T3397).
        if (self.as(gio.Application).getIsRemote() == 0) SessionLayout.startSync(self);

        // T3400: a dead or unreachable local agent is recovered in place -
        // its panes rebuilt on a fresh agent - instead of left frozen.
        if (self.as(gio.Application).getIsRemote() == 0) AgentRecovery.start(self);

        // Ghoztty (T3410): a debug build's headless viewer test window. A
        // no-op unless GHOZTTY_TEST_VIEWER is set, and compiled out of a
        // release.
        if (self.as(gio.Application).getIsRemote() == 0) @import("../Viewer.zig").openTestWindowFromEnv();

        // If we are NOT the primary instance, then we never want to run.
        // This means that another instance of the GTK app is running.
        if (self.as(gio.Application).getIsRemote() != 0) {
            log.debug(
                "application is remote, exiting run loop after activation",
                .{},
            );
            return;
        }

        // Tell systemd that we are ready.
        systemd.notify.ready();

        log.debug("entering runloop", .{});
        defer log.debug("exiting runloop", .{});
        priv.running = true;
        while (priv.running) {
            _ = glib.MainContext.iteration(ctx, 1);

            // Tick the core Ghostty terminal app
            try priv.core_app.tick(priv.rt_app);

            // Check if we must quit based on the current state.
            const must_quit = q: {
                // If we are configured to always stay running, don't quit.
                const config = priv.config.get();
                if (!config.@"quit-after-last-window-closed") break :q false;

                // If the quit timer has expired, quit.
                if (priv.quit_timer == .expired) {
                    log.debug("must_quit due to quit timer expired", .{});
                    break :q true;
                }

                // If we have no windows attached to our app, also quit.
                // We only do this if we don't have the closed delay set,
                // because with the closed delay set we'll exit eventually.
                if (config.@"quit-after-last-window-closed-delay" == null) {
                    if (priv.requested_window and @as(
                        ?*glib.List,
                        self.as(gtk.Application).getWindows(),
                    ) == null) {
                        log.debug("must_quit due to no app windows", .{});
                        break :q true;
                    }
                }

                // No quit conditions met
                break :q false;
            };

            if (must_quit) {
                // All must quit scenarios do not need confirmation.
                // Furthermore, must quit scenarios may result in a situation
                // where its unsafe to even access the app/surface memory
                // since its in the process of being freed. We must simply
                // begin our exit immediately.
                self.quitNow();
            }
        }
    }

    /// Quit the application. This will start the process to stop the
    /// run loop. It will not `posix.exit`.
    pub fn quit(self: *Self) void {
        const priv = self.private();

        // If our run loop has already exited then we are done.
        if (!priv.running) return;

        // If our core app doesn't need to confirm quit then we
        // can exit immediately.
        if (!priv.core_app.needsConfirmQuit()) {
            self.quitNow();
            return;
        }

        // Get the parent for our dialog
        const parent: ?*gtk.Widget = parent: {
            const list = gtk.Window.listToplevels();
            defer list.free();
            const focused = @as(?*glib.List, list.findCustom(
                null,
                findActiveWindow,
            )) orelse {
                // If we have an active surface then we should have
                // a window available but in the rare case we don't we
                // should exit so we don't crash.
                break :parent null;
            };
            break :parent @ptrCast(@alignCast(focused.f_data));
        };

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.app);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Application,
            handleCloseConfirmation,
            self,
            .{},
        );

        // Show it
        dialog.present(parent);
    }

    /// `handoff-quit` (T1070 on win32, T3399a here): a launch of a DIFFERENT
    /// build asked this instance to quit so it can take its place. The quit
    /// is deferred so the IPC reply - which tells the launch to wait for this
    /// process to exit - is written before the app goes. It is the ordinary
    /// `quitNow` (no confirmation: the user answered the launch's question),
    /// so the layout is saved and every agent-hosted pane detaches for the
    /// new build's restore to re-attach.
    pub fn scheduleHandoffQuit(self: *Self) void {
        _ = glib.timeoutAdd(handoff_quit_delay_ms, handleHandoffQuitTimer, self);
    }

    const handoff_quit_delay_ms: c_uint = 150;

    fn handleHandoffQuitTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_REMOVE)));
        log.info("handoff-quit: quitting so another build can take over", .{});
        if (self.private().running) self.quitNow();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    /// True once the app has begun quitting (T3337). See `Private.quitting`.
    pub fn isQuitting(self: *Self) bool {
        return self.private().quitting;
    }

    fn quitNow(self: *Self) void {
        // T3397: record the layout (screens included) while every window
        // still stands; nothing writes it after this, so the teardown below
        // can never save an empty app over it.
        SessionLayout.finishForQuit(self);
        self.private().quitting = true;
        // T3384: a pane parked for undo was closed by the user, so it ends
        // (its session too) rather than riding out the quit as a detach.
        CloseUndo.dropAll();
        // Get all our windows and destroy them, forcing them to free.
        const list = gtk.Window.listToplevels();
        defer list.free();
        list.foreach(struct {
            fn callback(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const ptr = data orelse return;
                const window: *gtk.Window = @ptrCast(@alignCast(ptr));

                // We only want to destroy our windows. These windows own
                // every other type of window that is possible so this will
                // trigger a proper shutdown sequence.
                //
                // We previously just destroyed ALL windows but this leads to
                // a double-free with the fcitx ime, because it has a nested
                // gtk.Window as a property that we don't own and it later
                // tries to free on its own. I think this is probably a bug in
                // the fcitx ime widget but still, we don't want a double free!
                if (gobject.ext.isA(window, Window)) {
                    window.destroy();
                }
            }
        }.callback, null);

        // Trigger our runloop exit.
        self.private().running = false;
    }

    /// apprt API to perform an action.
    pub fn performAction(
        self: *Self,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .close_tab => return Action.closeTab(target, value),
            .close_window => return Action.closeWindow(target),

            .copy_title_to_clipboard => return Action.copyTitleToClipboard(target),

            .config_change => try Action.configChange(
                self,
                target,
                value.config,
            ),

            .desktop_notification => Action.desktopNotification(self, target, value),

            .equalize_splits => return Action.equalizeSplits(target),

            // Undo/redo a pane close or a `+rearrange` (T3384; Mac's
            // NSUndoManager, win32 T1825/T2234). A surface target scopes it to
            // that window, as Mac's per-window undo manager does; the app
            // target takes the most recent one anywhere. Nothing to undo
            // answers "not performed".
            .undo => return CloseUndo.undo(switch (target) {
                .app => null,
                .surface => |v| v.rt_surface.surface,
            }),
            .redo => return CloseUndo.redo(switch (target) {
                .app => null,
                .surface => |v| v.rt_surface.surface,
            }),

            .goto_split => return Action.gotoSplit(target, value),

            .swap_split => return Action.swapSplit(target, value),

            .goto_window => return Action.gotoWindow(value),

            .goto_tab => return Action.gotoTab(target, value),

            .initial_size => return Action.initialSize(target, value),

            .inspector => return Action.controlInspector(target, value),

            .key_sequence => return Action.keySequence(target, value),
            .key_table => return Action.keyTable(target, value),

            .mouse_over_link => Action.mouseOverLink(target, value),
            .mouse_shape => Action.mouseShape(target, value),
            .mouse_visibility => Action.mouseVisibility(target, value),

            .move_tab => return Action.moveTab(target, value),

            .new_split => return Action.newSplit(target, value),

            .new_tab => return Action.newTab(target),

            .new_window => try Action.newWindow(
                self,
                switch (target) {
                    .app => null,
                    .surface => |v| v,
                },
                .none,
            ),

            .open_config => return Action.openConfig(self),

            .open_url => Action.openUrl(self, value),

            .pwd => Action.pwd(target, value),

            .present_terminal => return Action.presentTerminal(target),

            .progress_report => return Action.progressReport(target, value),

            .prompt_title => return Action.promptTitle(target, value),

            .quit => self.quit(),

            .quit_timer => try Action.quitTimer(self, value),

            .reload_config => try Action.reloadConfig(self, target, value),

            .render => Action.render(target),

            .resize_split => return Action.resizeSplit(target, value),

            .ring_bell => Action.ringBell(target),

            .scrollbar => Action.scrollbar(target, value),

            .set_title => Action.setTitle(target, value),
            .set_tab_title => return Action.setTabTitle(target, value),

            .show_child_exited => return Action.showChildExited(target, value),

            .show_gtk_inspector => Action.showGtkInspector(),

            .size_limit => return Action.sizeLimit(target, value),

            .toggle_maximize => Action.toggleMaximize(target),
            .toggle_fullscreen => Action.toggleFullscreen(target),
            .toggle_quick_terminal => return Action.toggleQuickTerminal(self),
            .toggle_tab_overview => return Action.toggleTabOverview(target),
            .toggle_window_decorations => return Action.toggleWindowDecorations(target),
            .toggle_command_palette => return Action.toggleCommandPalette(target),
            .toggle_split_zoom => return Action.toggleSplitZoom(target),
            .show_on_screen_keyboard => return Action.showOnScreenKeyboard(target),
            .command_finished => return Action.commandFinished(target, value),
            .readonly => return Action.setReadonly(target, value),

            .start_search => Action.startSearch(target, value),
            .end_search => Action.endSearch(target),
            .search_total => Action.searchTotal(target, value),
            .search_selected => Action.searchSelected(target, value),

            .pane_banner => return Action.paneBanner(target, value),
            .activity_state => return Action.activityState(target, value),

            // Unimplemented
            .secure_input,
            .close_all_windows,
            .float_window,
            .toggle_visibility,
            .toggle_background_opacity,
            .cell_size,
            .render_inspector,
            .renderer_health,
            .color_change,
            .reset_window_size,
            .check_for_updates,
            .show_keyboard_shortcuts,
            => {
                log.warn("unimplemented action={}", .{action});
                return false;
            },

            // Ghoztty actions the GTK frontend has not been taught yet
            // (T3330 L1 bring-up). Each is a Linux-seat port task; the list
            // and owners are in docs/design/windows-parity-tasks/T3330.md.
            .toggle_pane_sidebar => return Action.togglePaneSidebar(self),
            .prompt_banner => return Action.promptBanner(self, target),

            .toggle_hero_mode,
            .toggle_rearrange_mode,
            .stash_pane,
            .restore_stashed_pane,
            => {
                log.warn("ghoztty action not ported to gtk yet action={}", .{action});
                return false;
            },
        }

        // Assume it was handled. The unhandled case must be explicit
        // in the switch above.
        return true;
    }

    /// Returns the core app associated with this application. This is
    /// not a reference-counted type so you should not store this.
    pub fn core(self: *Self) *CoreApp {
        return self.private().core_app;
    }

    /// Returns the apprt application associated with this application.
    pub fn rt(self: *Self) *ApprtApp {
        return self.private().rt_app;
    }

    // -----------------------------------------------------------------
    // App keybindings from a viewer pane (T3430)

    /// A key press the focused VIEWER pane `surface` did not claim itself:
    /// is it an app keybinding a viewer may perform (`viewer_chrome.route`)?
    /// True takes it from the page; the action then runs one main-loop hop
    /// later, because it may close the very pane whose key handler is still
    /// on the stack (win32 posts `WM_APP_VIEWER_ACCEL` for the same reason).
    /// The binding is resolved again when it runs, so a config reload in
    /// between is honoured.
    pub fn viewerChord(self: *Self, surface: *Surface, event: input.KeyEvent) bool {
        const leaf = CoreApp.bindingForEvent(self.private().config.get(), event) orelse return false;
        const r = viewer_chrome.route(&leaf, hostTerminal(surface) != null);
        if (r == .pass) return false;
        const pending = std.heap.c_allocator.create(PendingViewerChord) catch return false;
        pending.* = .{ .surface = surface.ref(), .event = event };
        _ = glib.idleAdd(runViewerChord, pending);
        log.debug("viewer chord: {t} route={t}", .{ event.key, r });
        return true;
    }

    const PendingViewerChord = struct {
        surface: *Surface,
        event: input.KeyEvent,
    };

    fn runViewerChord(ud: ?*anyopaque) callconv(.c) c_int {
        const pending: *PendingViewerChord = @ptrCast(@alignCast(ud orelse return 0));
        defer std.heap.c_allocator.destroy(pending);
        const surface = pending.surface;
        defer surface.unref();
        _ = default().performViewerChord(surface, pending.event);
        return 0;
    }

    /// Carry out a viewer chord `viewerChord` claimed. Returns whether
    /// anything was performed.
    pub fn performViewerChord(self: *Self, surface: *Surface, event: input.KeyEvent) bool {
        const priv = self.private();
        // The pane may have closed in the hop (another chord, a script).
        if (!surface.isViewer()) return false;
        const leaf = CoreApp.bindingForEvent(priv.config.get(), event) orelse return false;
        const host = hostTerminal(surface);
        const actions = leaf.actionsSlice();
        switch (viewer_chrome.route(&leaf, host != null)) {
            .pass => return false,
            .native => {
                const action = actions[0];
                const ok = performViewerBinding(surface, action);
                log.info("viewer chord: {t} performed on the viewer ok={}", .{ action, ok });
                return ok;
            },
            .core => {
                if (leaf.flags.global or leaf.flags.all) {
                    priv.core_app.performAllChainedAction(priv.rt_app, actions);
                    return true;
                }
                var performed = false;
                for (actions) |action| {
                    const v = priv.core_app.performActionForNonTerminal(priv.rt_app, host, action);
                    performed = performed or v;
                    if (v and CoreSurface.closingAction(action)) break;
                }
                log.info("viewer chord: {d} action(s) through the core performed={}", .{ actions.len, performed });
                return performed;
            },
        }
    }

    /// One binding action chosen while a VIEWER pane is the active one - a
    /// command palette entry (T3430; win32 `menuRoute`, T2356). The same
    /// route as the keyboard's, so an entry answers from a viewer exactly as
    /// its chord does; a terminal-only entry does nothing rather than act on
    /// a terminal the user is not looking at.
    pub fn performViewerAction(self: *Self, surface: *Surface, action: input.Binding.Action) bool {
        const priv = self.private();
        const leaf: input.Binding.Set.GenericLeaf = .{ .flags = .{}, .actions = .{ .single = .{action} } };
        const host = hostTerminal(surface);
        return switch (viewer_chrome.route(&leaf, host != null)) {
            .pass => pass: {
                log.info("viewer action: {t} needs a terminal; not performed", .{action});
                break :pass false;
            },
            .native => performViewerBinding(surface, action),
            .core => priv.core_app.performActionForNonTerminal(priv.rt_app, host, action),
        };
    }

    /// A terminal in the viewer's own window for the core to perform a
    /// window-scoped action through: the active tab's first, then any.
    /// Null in a window of nothing but viewers.
    fn hostTerminal(viewer: *Surface) ?*CoreSurface {
        const window = ext.getAncestor(Window, viewer.as(gtk.Widget)) orelse return null;
        if (window.getSelectedTab()) |tab| if (tab.getSurfaceTree()) |tree| {
            var it = tree.iterator();
            while (it.next()) |entry| if (entry.view.core()) |c| return c;
        };
        for (default().core().surfaces.items) |s| {
            const c = s.core();
            const w = ext.getAncestor(Window, s.gobj().as(gtk.Widget)) orelse continue;
            if (w == window) return c;
        }
        return null;
    }

    /// Perform `action` on the focused viewer pane `surface` itself - what
    /// its core surface would have done, for the actions
    /// `viewer_chrome.nativeTag` admits: the split, close and zoom act on
    /// the viewer, the tab and window ones on its window. Also the command
    /// palette's way in for a viewer-only window, which has no core surface
    /// to run an entry through. Returns whether it was performed.
    pub fn performViewerBinding(surface: *Surface, action: input.Binding.Action) bool {
        const widget = surface.as(gtk.Widget);
        const window = ext.getAncestor(Window, widget);
        const tree = ext.getAncestor(SplitTree, widget);
        const goto = struct {
            fn of(to: input.Binding.Action.SplitFocusDirection) Surface.Tree.Goto {
                return switch (to) {
                    .previous => .previous_wrapped,
                    .next => .next_wrapped,
                    .up => .{ .spatial = .up },
                    .down => .{ .spatial = .down },
                    .left => .{ .spatial = .left },
                    .right => .{ .spatial = .right },
                };
            }
        };
        switch (action) {
            .new_tab => {
                const w = window orelse return false;
                w.newTab(hostTerminal(surface));
                return true;
            },
            .close_tab => |v| return widget.activateAction(
                "tab.close",
                glib.ext.VariantType.stringFor([:0]const u8),
                @as([*:0]const u8, @tagName(v)),
            ) != 0,
            inline .previous_tab, .next_tab, .last_tab, .goto_tab => |v, tag| {
                const w = window orelse return false;
                return w.selectTab(switch (tag) {
                    .previous_tab => .previous,
                    .next_tab => .next,
                    .last_tab => .last,
                    .goto_tab => .{ .n = @intCast(v) },
                    else => comptime unreachable,
                });
            },
            .move_tab => |amount| {
                const w = window orelse return false;
                return w.moveTab(surface, @intCast(amount));
            },
            .close_window => return widget.activateAction("win.close", null) != 0,
            .toggle_fullscreen => surface.toggleFullscreen(),
            .toggle_maximize => surface.toggleMaximize(),
            .toggle_tab_overview => (window orelse return false).toggleTabOverview(),
            .toggle_window_decorations => (window orelse return false).toggleWindowDecorations(),
            .toggle_command_palette => return surface.toggleCommandPalette(),
            .prompt_tab_title, .prompt_window_title => {
                const tab = ext.getAncestor(Tab, widget) orelse return false;
                tab.promptTabTitle();
            },
            .equalize_splits => return widget.activateAction("split-tree.equalize", null) != 0,
            .new_split => |direction| {
                const dir: apprt.action.SplitDirection = switch (direction) {
                    .right => .right,
                    .left => .left,
                    .down => .down,
                    .up => .up,
                    .auto => if (widget.getWidth() > widget.getHeight()) .right else .down,
                };
                // Off THIS pane, not whichever the tree last saw focused.
                const t = tree orelse return false;
                t.newSplit(switch (dir) {
                    .right => .right,
                    .left => .left,
                    .down => .down,
                    .up => .up,
                }, surface, .{}) catch |err| {
                    log.warn("viewer chord: new_split failed err={}", .{err});
                    return false;
                };
            },
            .goto_split => |to| return (tree orelse return false).goto(goto.of(to)),
            .swap_split => |to| return (tree orelse return false).swapSplit(goto.of(to)),
            .resize_split => |value| {
                const t = tree orelse return false;
                if (!t.getIsSplit()) return false;
                return t.resize(switch (value[0]) {
                    .up => .up,
                    .down => .down,
                    .left => .left,
                    .right => .right,
                }, value[1]) catch |err| {
                    log.warn("viewer chord: resize_split failed err={}", .{err});
                    return false;
                };
            },
            .toggle_split_zoom => {
                const t = tree orelse return false;
                if (!t.getIsSplit()) return false;
                return widget.activateAction("split-tree.zoom", null) != 0;
            },
            .close_surface => surface.close(),
            else => {
                // `nativeTag` admitted something this switch does not handle.
                log.warn("viewer chord: no viewer handler for {t}", .{action});
                return false;
            },
        }
        return true;
    }

    /// Returns the app winproto implementation.
    pub fn winproto(self: *Self) *winprotopkg.App {
        return &self.private().winproto;
    }

    /// Returns the open URI portal implementation.
    pub fn openUri(self: *Self) *OpenURI {
        return &self.private().open_uri;
    }

    /// This will get called when there are no more open surfaces.
    fn startQuitTimer(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // Cancel any previous timer.
        self.stopQuitTimer();

        // This is a no-op unless we are configured to quit after last window is closed.
        if (!config.@"quit-after-last-window-closed") return;

        // If a delay is configured, set a timeout function to quit after the delay.
        if (config.@"quit-after-last-window-closed-delay") |v| {
            priv.quit_timer = .{
                .active = glib.timeoutAdd(
                    v.asMilliseconds(),
                    handleQuitTimerExpired,
                    self,
                ),
            };
        } else {
            // If no delay is configured, treat it as expired.
            priv.quit_timer = .expired;
        }
    }

    /// This will get called when a new surface gets opened.
    fn stopQuitTimer(self: *Self) void {
        const priv = self.private();
        switch (priv.quit_timer) {
            .off => {},
            .expired => priv.quit_timer = .off,
            .active => |source| {
                if (glib.Source.remove(source) == 0) {
                    log.warn(
                        "unable to remove quit timer source={d}",
                        .{source},
                    );
                }

                priv.quit_timer = .off;
            },
        }
    }

    fn loadRuntimeCss(self: *Self) (Allocator.Error || std.Io.Writer.Error)!void {
        const alloc = self.allocator();
        const priv: *Private = self.private();
        const config = priv.config.get();

        var buf: std.Io.Writer.Allocating = try .initCapacity(alloc, 2048);
        defer buf.deinit();

        const writer = &buf.writer;

        // Load standard css first as it can override some of the user configured styling.
        try loadRuntimeCss414(config, writer);
        try loadRuntimeCss416(config, writer);

        const unfocused_fill: CoreConfig.Color = config.@"unfocused-split-fill" orelse config.background;

        try writer.print(
            \\widget.unfocused-split {{
            \\ opacity: {d:.2};
            \\ background-color: rgb({d},{d},{d});
            \\}}
            \\
        , .{
            1.0 - config.@"unfocused-split-opacity",
            unfocused_fill.r,
            unfocused_fill.g,
            unfocused_fill.b,
        });

        if (config.@"split-divider-color") |color| {
            try writer.print(
                \\.window .split paned > separator {{
                \\  color: rgb({[r]d},{[g]d},{[b]d});
                \\  background: rgb({[r]d},{[g]d},{[b]d});
                \\}}
                \\
            , .{
                .r = color.r,
                .g = color.g,
                .b = color.b,
            });
        }

        if (config.@"window-title-font-family") |font_family| {
            try writer.print(
                \\.window headerbar {{
                \\  font-family: "{[font_family]s}";
                \\}}
                \\
            , .{ .font_family = font_family });
        }

        const contents = buf.written();

        log.debug("runtime CSS is {d} bytes", .{contents.len});

        const bytes = glib.Bytes.new(contents.ptr, contents.len);
        defer bytes.unref();

        // Clears any previously loaded CSS from this provider
        priv.css_provider.loadFromBytes(bytes);
    }

    /// Load runtime CSS for older than GTK 4.16
    fn loadRuntimeCss414(
        config: *const CoreConfig,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (gtk_version.runtimeAtLeast(4, 16, 0)) return;

        const window_theme = config.@"window-theme";
        const headerbar_background = config.@"window-titlebar-background" orelse config.background;
        const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;

        switch (window_theme) {
            .ghostty => try writer.print(
                \\windowhandle {{
                \\  background-color: rgb({d},{d},{d});
                \\  color: rgb({d},{d},{d});
                \\}}
                \\windowhandle:backdrop {{
                \\ background-color: oklab(from rgb({d},{d},{d}) calc(l * 0.9) a b / alpha);
                \\}}
                \\
            , .{
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
                headerbar_foreground.r,
                headerbar_foreground.g,
                headerbar_foreground.b,
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
            }),
            else => {},
        }
    }

    /// Load runtime for GTK 4.16 and newer
    fn loadRuntimeCss416(
        config: *const CoreConfig,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (gtk_version.runtimeUntil(4, 16, 0)) return;

        const window_theme = config.@"window-theme";
        const headerbar_background = config.@"window-titlebar-background" orelse config.background;
        const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;

        try writer.writeAll(
            \\/*
            \\ * Child Exited Overlay
            \\ */
            \\
            \\.child-exited.normal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--success-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.child-exited.abnormal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Surface
            \\ */
            \\
            \\.surface progressbar.error trough progress {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.surface .bell-overlay {
            \\  border-color: color-mix(
            \\    in srgb,
            \\    var(--accent-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Splits
            \\ */
            \\
            \\.window .split paned > separator {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--window-bg-color),
            \\    transparent 0%
            \\  );
            \\}
            \\
        );

        switch (window_theme) {
            .ghostty => try writer.print(
                \\:root {{
                \\  --ghostty-fg: rgb({d},{d},{d});
                \\  --ghostty-bg: rgb({d},{d},{d});
                \\  --headerbar-fg-color: var(--ghostty-fg);
                \\  --headerbar-bg-color: var(--ghostty-bg);
                \\  --headerbar-backdrop-color: oklab(from var(--headerbar-bg-color) calc(l * 0.9) a b / alpha);
                \\  --overview-fg-color: var(--ghostty-fg);
                \\  --overview-bg-color: var(--ghostty-bg);
                \\  --popover-fg-color: var(--ghostty-fg);
                \\  --popover-bg-color: var(--ghostty-bg);
                \\  --window-fg-color: var(--ghostty-fg);
                \\  --window-bg-color: var(--ghostty-bg);
                \\}}
                \\windowhandle {{
                \\  background-color: var(--headerbar-bg-color);
                \\  color: var(--headerbar-fg-color);
                \\}}
                \\windowhandle:backdrop {{
                \\ background-color: var(--headerbar-backdrop-color);
                \\}}
            , .{
                headerbar_foreground.r,
                headerbar_foreground.g,
                headerbar_foreground.b,
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
            }),
            else => {},
        }
    }

    fn loadCustomCss(self: *Self) (std.fs.File.ReadError || Allocator.Error)!void {
        const priv: *Private = self.private();
        const alloc = self.allocator();
        const display = gdk.Display.getDefault() orelse {
            log.warn("unable to get display", .{});
            return;
        };

        // unload the previously loaded style providers
        for (priv.custom_css_providers.items) |provider| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                provider.as(gtk.StyleProvider),
            );
            provider.unref();
        }
        priv.custom_css_providers.clearRetainingCapacity();

        const config = priv.config.get();
        for (config.@"gtk-custom-css".value.items) |p| {
            const path, const optional = switch (p) {
                .optional => |path| .{ path, true },
                .required => |path| .{ path, false },
            };
            const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
                if (err != error.FileNotFound or !optional) {
                    log.warn(
                        "error opening gtk-custom-css file {s}: {}",
                        .{ path, err },
                    );
                }
                continue;
            };
            defer file.close();

            const css_file_size_limit = 5 * 1024 * 1024; // 5MB

            log.info("loading gtk-custom-css path={s}", .{path});
            const contents = file.readToEndAlloc(
                alloc,
                css_file_size_limit,
            ) catch |err| switch (err) {
                error.FileTooBig => {
                    log.warn("gtk-custom-css file {s} was larger than {Bi}", .{ path, css_file_size_limit });
                    continue;
                },
                else => |e| return e,
            };
            defer alloc.free(contents);

            const bytes = glib.Bytes.new(contents.ptr, contents.len);
            defer bytes.unref();

            const css_provider = gtk.CssProvider.new();
            errdefer css_provider.unref();

            _ = gtk.CssProvider.signals.parsing_error.connect(
                css_provider,
                *Self,
                signalCssParsingError,
                self,
                .{},
            );

            try priv.custom_css_providers.append(alloc, css_provider);

            css_provider.loadFromBytes(bytes);

            gtk.StyleContext.addProviderForDisplay(
                display,
                css_provider.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_USER,
            );
        }
    }

    fn syncActionAccelerators(self: *Self) void {
        self.syncActionAccelerator("app.quit", .{ .quit = {} });
        self.syncActionAccelerator("app.open-config", .{ .open_config = {} });
        self.syncActionAccelerator("app.reload-config", .{ .reload_config = {} });
        self.syncActionAccelerator("win.toggle-inspector", .{ .inspector = .toggle });
        self.syncActionAccelerator("app.show-gtk-inspector", .show_gtk_inspector);
        self.syncActionAccelerator("win.toggle-command-palette", .toggle_command_palette);
        self.syncActionAccelerator("win.close", .{ .close_window = {} });
        self.syncActionAccelerator("win.new-window", .{ .new_window = {} });
        self.syncActionAccelerator("win.new-tab", .{ .new_tab = {} });
        self.syncActionAccelerator("win.close-tab::this", .{ .close_tab = .this });
        self.syncActionAccelerator("tab.close::this", .{ .close_tab = .this });
        self.syncActionAccelerator("win.split-right", .{ .new_split = .right });
        self.syncActionAccelerator("win.split-down", .{ .new_split = .down });
        self.syncActionAccelerator("win.split-left", .{ .new_split = .left });
        self.syncActionAccelerator("win.split-up", .{ .new_split = .up });
        self.syncActionAccelerator("win.copy", .{ .copy_to_clipboard = .mixed });
        self.syncActionAccelerator("win.paste", .{ .paste_from_clipboard = {} });
        self.syncActionAccelerator("win.reset", .{ .reset = {} });
        self.syncActionAccelerator("win.clear", .{ .clear_screen = {} });
        self.syncActionAccelerator("win.prompt-title", .{ .prompt_surface_title = {} });
        self.syncActionAccelerator("split-tree.new-split::left", .{ .new_split = .left });
        self.syncActionAccelerator("split-tree.new-split::right", .{ .new_split = .right });
        self.syncActionAccelerator("split-tree.new-split::up", .{ .new_split = .up });
        self.syncActionAccelerator("split-tree.new-split::down", .{ .new_split = .down });
    }

    fn syncActionAccelerator(
        self: *Self,
        gtk_action: [:0]const u8,
        action: input.Binding.Action,
    ) void {
        const gtk_app = self.as(gtk.Application);

        // Reset it initially
        const zero = [_:null]?[*:0]const u8{};
        gtk_app.setAccelsForAction(gtk_action, &zero);

        const config = self.private().config.get();
        const trigger = config.keybind.set.getTrigger(action) orelse return;
        var buf: [1024]u8 = undefined;
        const accel = if (key.accelFromTrigger(
            &buf,
            trigger,
        )) |accel_|
            accel_ orelse return
        else |err| switch (err) {
            // This should really never, never happen. Its not critical enough
            // to actually crash, but this is a bug somewhere. An accelerator
            // for a trigger can't possibly be more than 1024 bytes.
            error.WriteFailed => {
                log.warn("accelerator somehow longer than 1024 bytes: {f}", .{trigger});
                return;
            },
        };
        const accels = [_:null]?[*:0]const u8{accel};

        gtk_app.setAccelsForAction(gtk_action, &accels);
    }

    //---------------------------------------------------------------
    // Properties

    /// Returns the configuration for this application.
    ///
    /// The reference count is increased.
    pub fn getConfig(self: *Self) *Config {
        return self.private().config.ref();
    }

    /// Open a window for an IPC `+new-window` (T3370) and return it.
    /// `take_focus` false shows it without asking for focus: a script's
    /// window opens in the background unless it passed `--focus` (T1797,
    /// T3381).
    pub fn newWindowForIpc(
        self: *Self,
        command: ?configpkg.Command,
        working_directory: ?[:0]const u8,
        env: []const []const u8,
        view: ?[:0]const u8,
        take_focus: bool,
    ) *Window {
        return Action.newWindowForIpc(self, .{
            .command = command,
            .working_directory = working_directory,
            .env = env,
            .view = view,
            .activate = take_focus,
        });
    }

    /// A window rebuilt by a session restore (T3397), at its recorded size
    /// (T3549) when there is one, set before it is presented so it maps at
    /// that size. Wayland gives a client no position, so where it lands
    /// stays the compositor's call.
    pub fn newWindowForRestore(self: *Self, view: ?[:0]const u8, size: ?WindowSize) *Window {
        return Action.newWindowForIpc(self, .{
            .view = view,
            .activate = true,
            .size = size,
        });
    }

    /// A viewer window at a page-requested size (T3447: an adopted popup's
    /// `window.open(u, n, "width=W,height=H")`), in front. Null size: the
    /// ordinary default.
    pub fn newViewerWindowSized(
        self: *Self,
        view: [:0]const u8,
        working_directory: ?[:0]const u8,
        size: ?WindowSize,
    ) *Window {
        return Action.newWindowForIpc(self, .{
            .working_directory = working_directory,
            .view = view,
            .activate = true,
            .size = size,
        });
    }

    /// Set the configuration for this application. The reference count
    /// is increased on the new configuration and the old one is
    /// unreferenced.
    ///
    /// If the config has errors this may show the config errors dialog.
    fn setConfig(self: *Self, config: *Config) void {
        const priv = self.private();
        priv.config.unref();
        priv.config = config.ref();
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        // Show our errors if we have any
        self.showConfigErrorsDialog();
    }

    fn propConfig(
        _: *Application,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Sync our accelerators for menu items.
        self.syncActionAccelerators();

        // `macos-pane-sidebar` (T3557): a changed value starts every
        // window's sidebar over; an unchanged one leaves the user's toggles.
        if (PaneSidebar.applyStart(self.getConfig().get().@"macos-pane-sidebar"))
            Window.refreshAllSidebars();

        // Load our runtime and custom CSS. If this fails then our window is
        // just stuck with the old CSS but we don't want to fail the entire
        // config change operation.
        self.loadRuntimeCss() catch |err| switch (err) {
            error.WriteFailed, error.OutOfMemory => log.warn(
                "out of memory loading runtime CSS, no runtime CSS applied",
                .{},
            ),
        };
        self.loadCustomCss() catch |err| {
            log.warn(
                "failed to load custom CSS, no custom CSS applied, err={}",
                .{err},
            );
        };
    }

    /// Log CSS parsing error
    fn signalCssParsingError(
        _: *gtk.CssProvider,
        css_section: *gtk.CssSection,
        err: *glib.Error,
        _: *Self,
    ) callconv(.c) void {
        const location = css_section.toString();
        defer glib.free(location);
        if (comptime gtk_version.atLeast(4, 16, 0)) bytes: {
            const bytes = css_section.getBytes() orelse break :bytes;
            var len: usize = undefined;
            const ptr = bytes.getData(&len) orelse break :bytes;
            const data = ptr[0..len];
            log.warn("css parsing failed at {s}: {s} {d} {s}\n{s}", .{
                location,
                glib.quarkToString(err.f_domain),
                err.f_code,
                err.f_message orelse "«unknown»",
                data,
            });
            return;
        }
        log.warn("css parsing failed at {s}: {s} {d} {s}", .{
            location,
            glib.quarkToString(err.f_domain),
            err.f_code,
            err.f_message orelse "«unknown»",
        });
    }

    //---------------------------------------------------------------
    // Libghostty Callbacks

    pub fn wakeup(self: *Self) void {
        _ = self;
        glib.MainContext.wakeup(null);
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn startup(self: *Self) callconv(.c) void {
        log.debug("startup", .{});

        gio.Application.virtual_methods.startup.call(
            Class.parent,
            self.as(Parent),
        );

        // Set ourselves as the default application.
        gio.Application.setDefault(self.as(gio.Application));

        // The D-Bus connection is only valid after GApplication startup.
        self.openUri().setDbusConnection(
            self.as(gio.Application).getDbusConnection(),
        );

        // Setup our event loop
        self.startupXev();

        // Setup our style manager (light/dark mode)
        self.startupStyleManager();

        // Setup some signal handlers
        self.startupSignals();

        // Setup our action map
        self.startupActionMap();

        // Setup our global shortcuts
        self.startupGlobalShortcuts();

        // If we have any config diagnostics from loading, then we
        // show the diagnostics dialog. We show this one as a general
        // modal (not to any specific window) because we don't even
        // know if the window will load.
        self.showConfigErrorsDialog();
    }

    /// Configure libxev to use a specific backend.
    ///
    /// This must be called before any other xev APIs are used.
    fn startupXev(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // If our backend is auto then we have no setup to do.
        if (config.@"async-backend" == .auto) return;

        // Setup our event loop backend to the preferred method
        const result: bool = switch (config.@"async-backend") {
            .auto => unreachable,
            .epoll => if (comptime xev.dynamic) xev.prefer(.epoll) else false,
            .io_uring => if (comptime xev.dynamic) xev.prefer(.io_uring) else false,
        };

        if (result) {
            log.info(
                "libxev manual backend={s}",
                .{@tagName(xev.backend)},
            );
        } else {
            log.warn(
                "libxev manual backend failed, using default={s}",
                .{@tagName(xev.backend)},
            );
        }
    }

    /// Setup the style manager on startup. The primary task here is to
    /// setup our initial light/dark mode based on the configuration and
    /// setup listeners for changes to the style manager.
    fn startupStyleManager(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // Setup our initial light/dark
        const style = self.as(adw.Application).getStyleManager();
        style.setColorScheme(switch (config.@"window-theme") {
            .auto, .ghostty => auto: {
                const lum = config.background.toTerminalRGB().perceivedLuminance();
                break :auto if (lum > 0.5)
                    .prefer_light
                else
                    .prefer_dark;
            },
            .system => .prefer_light,
            .dark => .force_dark,
            .light => .force_light,
        });

        // Setup color change notifications
        _ = gobject.Object.signals.notify.connect(
            style,
            *Self,
            handleStyleManagerDark,
            self,
            .{ .detail = "dark" },
        );

        // Do an initial color scheme sync. This is idempotent and does nothing
        // if our current theme matches what libghostty has so its safe to
        // call.
        handleStyleManagerDark(style, undefined, self);
    }

    /// Setup signal handlers
    fn startupSignals(self: *Self) void {
        const priv = self.private();
        assert(priv.signal_source == null);
        priv.signal_source = glib.unixSignalAdd(
            std.posix.SIG.USR2,
            handleSigusr2,
            self,
        );
        // Ghoztty (T3397): SIGTERM - what a logout or `systemctl stop` sends -
        // is a QUIT, not a crash: the layout is saved and every agent-backed
        // pane detaches, exactly as the Mac's applicationWillTerminate does at
        // logout. Lives as long as the app.
        _ = glib.unixSignalAdd(std.posix.SIG.TERM, handleSigterm, self);
    }

    /// SIGTERM handler via g_unix_signal_add (T3397): quit at once, no
    /// confirmation - nobody is there to answer one.
    fn handleSigterm(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_REMOVE)));
        log.info("received SIGTERM, quitting", .{});
        if (self.private().running) self.quitNow();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    /// Setup our action map.
    fn startupActionMap(self: *Self) void {
        const t_variant_type = glib.ext.VariantType.newFor(u64);
        defer t_variant_type.free();

        const as_variant_type = glib.VariantType.new("as");
        defer as_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("new-window", actionNewWindow, null),
            .init("new-window-command", actionNewWindow, as_variant_type),
            .init("open-config", actionOpenConfig, null),
            .init("present-surface", actionPresentSurface, t_variant_type),
            .init("quit", actionQuit, null),
            .init("reload-config", actionReloadConfig, null),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Setup our global shortcuts.
    fn startupGlobalShortcuts(self: *Self) void {
        const priv = self.private();

        // On startup, our dbus connection should be available.
        priv.global_shortcuts.setDbusConnection(
            self.as(gio.Application).getDbusConnection(),
        );

        // Setup a binding so that the shortcut config always matches the app.
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            priv.global_shortcuts.as(gobject.Object),
            "config",
            .{ .sync_create = true },
        );

        // Setup the signal handler for global shortcut triggers
        _ = GlobalShortcuts.signals.trigger.connect(
            priv.global_shortcuts,
            *Application,
            globalShortcutTrigger,
            self,
            .{},
        );
    }

    fn activate(self: *Self) callconv(.c) void {
        log.debug("activate", .{});

        // Queue a new window
        const priv = self.private();
        _ = priv.core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });

        // Call the parent activate method.
        gio.Application.virtual_methods.activate.call(
            Class.parent,
            self.as(Parent),
        );
    }

    /// Ghoztty (T3343): a `ghoztty://` link from the desktop (D-Bus `Open`).
    /// Focus-only and never creates a window - `url_scheme.openInApp`. Not
    /// chained to the parent, whose default only warns that `open` is
    /// unimplemented.
    fn open(
        self: *Self,
        files: [*]*gio.File,
        n_files: c_int,
        hint: [*:0]const u8,
    ) callconv(.c) void {
        _ = hint;
        const n: usize = @intCast(@max(n_files, 0));
        for (files[0..n]) |file| {
            const uri = file.getUri();
            defer glib.free(uri);
            url_scheme.openInApp(self, std.mem.span(uri));
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config_errors_dialog.get()) |diag| {
            diag.close();
            diag.unref(); // strong ref from get()
        }
        priv.config_errors_dialog.set(null);
        if (priv.signal_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove signal source", .{});
            }
            priv.signal_source = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    /// SIGUSR2 signal handler via g_unix_signal_add
    fn handleSigusr2(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_CONTINUE)));

        log.info("received SIGUSR2, reloading configuration", .{});
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            // If we fail to reload the configuration, then we want the
            // user to know it. For now we log but we should show another
            // GUI.
            log.warn("error reloading config: {}", .{err});
        };

        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    fn handleCloseConfirmation(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.quitNow();
    }

    fn handleQuitTimerExpired(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud));
        const priv = self.private();
        priv.quit_timer = .expired;
        return 0;
    }

    fn handleStyleManagerDark(
        style: *adw.StyleManager,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const scheme: apprt.ColorScheme = if (style.getDark() == 0)
            .light
        else
            .dark;
        log.debug("style manager changed scheme={}", .{scheme});

        const priv: *Private = self.private();
        const core_app = priv.core_app;
        core_app.colorSchemeEvent(self.rt(), scheme) catch |err| {
            log.warn("error updating app color scheme err={}", .{err});
        };
        for (core_app.surfaces.items) |surface| {
            surface.core().colorSchemeCallback(scheme) catch |err| {
                log.warn(
                    "unable to tell surface about color scheme change err={}",
                    .{err},
                );
            };
        }

        if (gtk_version.atLeast(4, 20, 0)) {
            const gtk_scheme: gtk.InterfaceColorScheme = switch (scheme) {
                .light => gtk.InterfaceColorScheme.light,
                .dark => gtk.InterfaceColorScheme.dark,
            };
            var value = gobject.ext.Value.newFrom(gtk_scheme);
            gobject.Object.setProperty(
                priv.css_provider.as(gobject.Object),
                "prefers-color-scheme",
                &value,
            );
            for (priv.custom_css_providers.items) |css_provider| {
                gobject.Object.setProperty(
                    css_provider.as(gobject.Object),
                    "prefers-color-scheme",
                    &value,
                );
            }
        }
    }

    fn handleReloadConfig(
        _: *ConfigErrorsDialog,
        self: *Self,
    ) callconv(.c) void {
        // We clear our dialog reference because its going to close
        // after response handling and we don't want to reuse it.
        const priv = self.private();
        priv.config_errors_dialog.set(null);

        // Reload our config as if the app reloaded.
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            // If we fail to reload the configuration, then we want the
            // user to know it. For now we log but we should show another
            // GUI.
            log.warn("error reloading config: {}", .{err});
        };
    }

    /// Show the config errors dialog if the config on our application
    /// has diagnostics.
    fn showConfigErrorsDialog(self: *Self) void {
        const priv = self.private();

        // If we already have a dialog, just update the config.
        if (priv.config_errors_dialog.get()) |diag| {
            defer diag.unref(); // get gets a strong ref

            var value = gobject.ext.Value.newFrom(priv.config);
            defer value.unset();
            gobject.Object.setProperty(
                diag.as(gobject.Object),
                "config",
                &value,
            );

            if (!priv.config.hasDiagnostics()) {
                diag.close();
            } else {
                diag.present(null);
            }

            return;
        }

        // No diagnostics, do nothing.
        if (!priv.config.hasDiagnostics()) return;

        // No dialog yet, initialize a new one. There's no need to unref
        // here because the widget that it becomes a part of takes ownership.
        const dialog: *ConfigErrorsDialog = .new(priv.config);
        priv.config_errors_dialog.set(dialog);

        // Connect to the reload signal so we know to reload our config.
        _ = ConfigErrorsDialog.signals.@"reload-config".connect(
            dialog,
            *Application,
            handleReloadConfig,
            self,
            .{},
        );

        // Show it
        dialog.present(null);
    }

    fn globalShortcutTrigger(
        _: *GlobalShortcuts,
        action: *const Binding.Action,
        self: *Self,
    ) callconv(.c) void {
        self.core().performAllAction(self.rt(), action.*) catch |err| {
            log.warn("failed to perform action={}", .{err});
        };
    }

    fn actionReloadConfig(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .reload_config) catch |err| {
            log.warn("error reloading config err={}", .{err});
        };
    }

    fn actionQuit(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .quit) catch |err| {
            log.warn("error quitting err={}", .{err});
        };
    }

    /// Handle `app.new-window` and `app.new-window-command` GTK actions
    pub fn actionNewWindow(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        log.debug("received new window action", .{});

        var arena: std.heap.ArenaAllocator = .init(Application.default().allocator());
        defer arena.deinit();

        const alloc = arena.allocator();

        var working_directory: ?[:0]const u8 = null;
        var title: ?[:0]const u8 = null;
        var command: ?configpkg.Command = null;
        var args: std.ArrayList([:0]const u8) = .empty;

        overrides: {
            // were we given a parameter?
            const parameter = parameter_ orelse break :overrides;

            const as_variant_type = glib.VariantType.new("as");
            defer as_variant_type.free();

            // ensure that the supplied parameter is an array of strings
            if (glib.Variant.isOfType(parameter, as_variant_type) == 0) {
                log.warn("parameter is of type '{s}', not '{s}'", .{
                    parameter.getTypeString(),
                    as_variant_type.peekString()[0..as_variant_type.getStringLength()],
                });
                break :overrides;
            }

            const s_variant_type = glib.VariantType.new("s");
            defer s_variant_type.free();

            var it: glib.VariantIter = undefined;
            _ = it.init(parameter);

            var e_seen: bool = false;
            var i: usize = 0;

            while (it.nextValue()) |value| : (i += 1) {
                defer value.unref();

                // just to be sure
                if (value.isOfType(s_variant_type) == 0) continue;

                var len: usize = undefined;
                const buf = value.getString(&len);
                const str = buf[0..len];

                log.debug("new-window argument: {d} {s}", .{ i, str });

                if (e_seen) {
                    const duplicated = alloc.dupeZ(u8, str) catch |err| {
                        log.warn("unable to duplicate argument {d} {s}: {t}", .{ i, str, err });
                        break :overrides;
                    };
                    args.append(alloc, duplicated) catch |err| {
                        log.warn("unable to append argument {d} {s}: {t}", .{ i, str, err });
                        break :overrides;
                    };
                    continue;
                }

                if (std.mem.eql(u8, str, "-e")) {
                    e_seen = true;
                    continue;
                }

                if (lib.cutPrefix(u8, str, "--command=")) |v| {
                    var cmd: configpkg.Command = undefined;
                    cmd.parseCLI(alloc, v) catch |err| {
                        log.warn("unable to parse command: {t}", .{err});
                        continue;
                    };
                    command = cmd;
                    continue;
                }
                if (lib.cutPrefix(u8, str, "--working-directory=")) |v| {
                    working_directory = alloc.dupeZ(u8, std.mem.trim(u8, v, &std.ascii.whitespace)) catch |err| wd: {
                        log.warn("unable to duplicate working directory: {t}", .{err});
                        break :wd null;
                    };
                    continue;
                }
                if (lib.cutPrefix(u8, str, "--title=")) |v| {
                    title = alloc.dupeZ(u8, std.mem.trim(u8, v, &std.ascii.whitespace)) catch |err| t: {
                        log.warn("unable to duplicate title: {t}", .{err});
                        break :t null;
                    };
                    continue;
                }
            }
        }

        if (args.items.len > 0) {
            command = .{
                .direct = args.items,
            };
        }

        Action.newWindow(self, null, .{
            .command = command,
            .working_directory = working_directory,
            .title = title,
        }) catch |err| {
            log.warn("unable to create new window: {t}", .{err});
        };
    }

    pub fn actionOpenConfig(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = self.core().mailbox.push(.open_config, .forever);
    }

    fn actionPresentSurface(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const parameter = parameter_ orelse return;

        const t = glib.ext.VariantType.newFor(u64);
        defer glib.VariantType.free(t);

        // Make sure that we've received a u64 from the system.
        if (glib.Variant.isOfType(parameter, t) == 0) {
            return;
        }

        // Convert the u64 to a core surface by using it as a surface ID.
        // A value of zero means that there was no target surface for the
        // notification so we don't focus any surface.
        const surface_id = parameter.getUint64();
        if (surface_id == 0) return;
        const surface = self.core().findSurfaceByID(surface_id) orelse return;

        _ = self.core().mailbox.push(
            .{
                .surface_message = .{
                    .surface = surface,
                    .message = .present_surface,
                },
            },
            .forever,
        );
    }

    //----------------------------------------------------------------
    // Boilerplate/Noise

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
            // Register our compiled resources exactly once.
            {
                const c = @cImport({
                    // generated header files
                    @cInclude("ghostty_resources.h");
                });
                if (c.ghostty_get_resource()) |ptr| {
                    gio.resourcesRegister(@ptrCast(@alignCast(ptr)));
                } else {
                    // If we fail to load resources then things will
                    // probably look really bad but it shouldn't stop our
                    // app from loading.
                    log.warn("unable to load resources", .{});
                }
            }

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Virtual methods
            gio.Application.virtual_methods.activate.implement(class, &activate);
            gio.Application.virtual_methods.open.implement(class, &open);
            gio.Application.virtual_methods.startup.implement(class, &startup);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };

    pub fn openUrlFallback(self: *Application, kind: apprt.action.OpenUrl.Kind, url: []const u8) void {
        // Fallback to the minimal cross-platform way of opening a URL.
        // This is always a safe fallback and enables for example Windows
        // to open URLs (GTK on Windows via WSL is a thing).
        internal_os.open(
            self.allocator(),
            kind,
            url,
        ) catch |err| log.warn("unable to open url: {}", .{err});
    }
};

/// All apprt action handlers
const Action = struct {
    pub fn closeTab(target: apprt.Target, value: apprt.Action.Value(.close_tab)) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction(
                    "tab.close",
                    glib.ext.VariantType.stringFor([:0]const u8),
                    @as([*:0]const u8, @tagName(value)),
                ) != 0;
            },
        }
    }

    pub fn closeWindow(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("win.close", null) != 0;
            },
        }
    }

    pub fn copyTitleToClipboard(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.gobj().copyTitleToClipboard(),
        };
    }

    pub fn configChange(
        self: *Application,
        target: apprt.Target,
        new_config: *const CoreConfig,
    ) !void {
        // Wrap our config in a GObject. This will clone it.
        const alloc = self.allocator();
        const config_obj: *Config = try .new(alloc, new_config);
        defer config_obj.unref();

        switch (target) {
            .surface => |core| core.rt_surface.surface.setConfig(config_obj),
            .app => self.setConfig(config_obj),
        }
    }

    pub fn desktopNotification(
        self: *Application,
        target: apprt.Target,
        n: apprt.action.DesktopNotification,
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| {
                v.rt_surface.gobj().sendDesktopNotification(n.title, n.body);
                return;
            },
        }

        // Set a default title if we don't already have one
        const t = switch (n.title.len) {
            0 => "Ghostty",
            else => n.title,
        };

        const notification = gio.Notification.new(t);
        defer notification.unref();
        notification.setBody(n.body);

        const icon = gio.ThemedIcon.new("com.dzearing.ghoztty");
        defer icon.unref();
        notification.setIcon(icon.as(gio.Icon));
        notification.setDefaultActionAndTargetValue(
            "app.present-surface",
            glib.Variant.newUint64(0),
        );

        // We set the notification ID to the body content. If the content is the
        // same, this notification may replace a previous notification
        const gio_app = self.as(gio.Application);
        gio_app.sendNotification(n.body, notification);
    }

    pub fn equalizeSplits(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("equalize splits to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("split-tree.equalize", null) != 0;
            },
        }
    }

    pub fn gotoSplit(
        target: apprt.Target,
        to: apprt.action.GotoSplit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                // Design note: we can't use widget actions here because
                // we need to know whether there is a goto target for returning
                // the proper perform result (boolean).

                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring goto_split", .{});
                    return false;
                };

                return tree.goto(switch (to) {
                    .previous => .previous_wrapped,
                    .next => .next_wrapped,
                    .up => .{ .spatial = .up },
                    .down => .{ .spatial = .down },
                    .left => .{ .spatial = .left },
                    .right => .{ .spatial = .right },
                });
            },
        }
    }

    pub fn swapSplit(
        target: apprt.Target,
        to: apprt.action.GotoSplit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring swap_split", .{});
                    return false;
                };

                return tree.swapSplit(switch (to) {
                    .previous => .previous_wrapped,
                    .next => .next_wrapped,
                    .up => .{ .spatial = .up },
                    .down => .{ .spatial = .down },
                    .left => .{ .spatial = .left },
                    .right => .{ .spatial = .right },
                });
            },
        }
    }

    pub fn gotoTab(
        target: apprt.Target,
        tab: apprt.action.GotoTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                return window.selectTab(switch (tab) {
                    .previous => .previous,
                    .next => .next,
                    .last => .last,
                    else => .{ .n = @intCast(@intFromEnum(tab)) },
                });
            },
        }
    }

    pub fn gotoWindow(direction: apprt.action.GotoWindow) bool {
        const glist = gtk.Window.listToplevels();
        defer glist.free();

        // The window we're starting from is typically our active window.
        const starting: *glib.List = @as(?*glib.List, glist.findCustom(
            null,
            findActiveWindow,
        )) orelse glist;

        // Go forward or backwards in the list until we find a valid
        // window that is visible.
        var current_: ?*glib.List = starting;
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }

        // If we reached here, we didn't find a valid window to focus.
        // Wrap around.
        current_ = switch (direction) {
            .next => glist,
            .previous => last: {
                var end: *glib.List = glist;
                while (end.f_next) |next| end = next;
                break :last end;
            },
        };
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            if (current_ == starting) break;
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }

        return false;
    }

    fn gotoWindowMaybe(gtk_window: *gtk.Window) bool {
        // If it is already active skip it.
        if (gtk_window.isActive() != 0) return false;
        // If it is hidden, skip it.
        if (gtk_window.as(gtk.Widget).isVisible() == 0) return false;
        // If it isn't a Ghostty window, skip it.
        const window = gobject.ext.cast(
            Window,
            gtk_window,
        ) orelse return false;

        // Focus our active surface
        const surface = window.getActiveSurface() orelse return false;
        gtk.Window.present(gtk_window);
        surface.grabFocus();
        return true;
    }

    pub fn initialSize(
        target: apprt.Target,
        value: apprt.action.InitialSize,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                surface.setDefaultSize(.{
                    .width = value.width,
                    .height = value.height,
                });
                return true;
            },
        }
    }

    pub fn mouseOverLink(
        target: apprt.Target,
        value: apprt.action.MouseOverLink,
    ) void {
        switch (target) {
            .app => log.warn("mouse over link to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHoverUrl(
                if (value.url.len > 0) value.url else null,
            ),
        }
    }

    pub fn mouseShape(
        target: apprt.Target,
        shape: terminal.MouseShape,
    ) void {
        switch (target) {
            .app => log.warn("mouse shape to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseShape(shape),
        }
    }

    pub fn mouseVisibility(
        target: apprt.Target,
        visibility: apprt.action.MouseVisibility,
    ) void {
        switch (target) {
            .app => log.warn("mouse visibility to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHidden(switch (visibility) {
                .visible => false,
                .hidden => true,
            }),
        }
    }

    pub fn moveTab(
        target: apprt.Target,
        value: apprt.action.MoveTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                return window.moveTab(
                    surface,
                    @intCast(value.amount),
                );
            },
        }
    }

    pub fn newSplit(
        target: apprt.Target,
        direction: apprt.action.SplitDirection,
    ) bool {
        switch (target) {
            .app => {
                log.warn("new split to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                const surface = core.rt_surface.surface;

                return surface.as(gtk.Widget).activateAction(
                    "split-tree.new-split",
                    "&s",
                    @tagName(direction).ptr,
                ) != 0;
            },
        }
    }

    pub fn newTab(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("new tab to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                // Get the window ancestor of the surface. Surfaces shouldn't
                // be aware they might be in windows but at the app level we
                // can do this.
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };
                window.newTab(core);
                return true;
            },
        }
    }

    pub fn newWindow(
        self: *Application,
        parent: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) !void {
        // Note that we've requested a window at least once. This is used
        // to trigger quit on no windows. Note I'm not sure if this is REALLY
        // necessary, but I don't want to risk a bug where on a slow machine
        // or something we quit immediately after starting up because there
        // was a delay in the event loop before we created a Window.
        self.private().requested_window = true;

        const win = Window.new(self, .{
            .title = overrides.title,
        });
        initAndShowWindow(
            self,
            win,
            parent,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }

    /// `newWindow` for an IPC `+new-window` (T3370): the first pane also
    /// gets `env` (`KEY=VALUE`), and the caller gets the window back to name,
    /// title and split.
    pub fn newWindowForIpc(
        self: *Application,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            env: []const []const u8 = &.{},
            view: ?[:0]const u8 = null,
            activate: bool = true,
            /// A size a page asked for (T3447), in place of the estimate.
            size: ?WindowSize = null,
        },
    ) *Window {
        self.private().requested_window = true;
        const win = Window.new(self, .none);
        initAndShowWindow(self, win, null, .{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .env = overrides.env,
            .view = overrides.view,
            .activate = overrides.activate,
            .size = overrides.size,
        });
        return win;
    }

    fn initAndShowWindow(
        self: *Application,
        win: *Window,
        parent: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,
            env: []const []const u8 = &.{},
            view: ?[:0]const u8 = null,
            /// False: show the window without asking for focus (T3381).
            activate: bool = true,
            /// The window's size, in place of the surface's estimate (T3447).
            size: ?WindowSize = null,

            pub const none: @This() = .{};
        },
    ) void {
        // Setup a binding so that whenever our config changes so does the
        // window. There's never a time when the window config should be out
        // of sync with the application config.
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            win.as(gobject.Object),
            "config",
            .{},
        );

        // Create a new tab with window context (first tab in new window)
        win.newTabForWindow(parent, .{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
            .env = overrides.env,
            .view = overrides.view,
        });

        // Estimate the initial window size before presenting so the window
        // manager can position it correctly.
        if (win.getActiveSurface()) |surface| {
            surface.estimateInitialSize();
            if (surface.getDefaultSize()) |size| {
                win.as(gtk.Window).setDefaultSize(
                    @intCast(size.width),
                    @intCast(size.height),
                );
            }
        }
        // A page's own request wins over the estimate (T3447).
        if (overrides.size) |s| win.as(gtk.Window).setDefaultSize(s.w, s.h);

        // Show the window. `present` is show + an activation request (on
        // Wayland, xdg-activation). A window a script opened without
        // `--focus` is only shown, so it does not take the keyboard from
        // whatever the user is typing into (T1797, T3381): realize first so
        // the window protocol can mark it not-focus-on-map (X11 user time
        // 0; Wayland has no such hint and simply is not asked).
        if (overrides.activate) {
            gtk.Window.present(win.as(gtk.Window));
            return;
        }
        win.as(gtk.Widget).realize();
        win.winproto().suppressFocusOnMap();
        win.as(gtk.Widget).setVisible(1);
        log.info("window shown in the background (no activation request)", .{});
    }

    pub fn openConfig(self: *Application) bool {
        // Get the config file path
        const alloc = self.allocator();
        const path = configpkg.edit.openPath(alloc) catch |err| {
            log.warn("error getting config file path: {}", .{err});
            return false;
        };
        defer alloc.free(path);

        // Open it using openURL. "path" isn't actually a URL but
        // at the time of writing that works just fine for GTK.
        openUrl(self, .{ .kind = .text, .url = path });
        return true;
    }

    pub fn openUrl(
        self: *Application,
        value: apprt.action.OpenUrl,
    ) void {
        if (std.mem.startsWith(u8, value.url, "/")) {
            self.openUrlFallback(value.kind, value.url);
            return;
        }
        if (std.mem.startsWith(u8, value.url, "file://")) {
            self.openUrlFallback(value.kind, value.url);
            return;
        }

        self.openUri().start(value) catch |err| {
            log.err("unable to open uri err={}", .{err});
            self.openUrlFallback(value.kind, value.url);
            return;
        };
    }

    pub fn pwd(
        target: apprt.Target,
        value: apprt.action.Pwd,
    ) void {
        switch (target) {
            .app => log.warn("pwd to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setPwd(value.pwd),
        }
    }

    pub fn quitTimer(
        self: *Application,
        mode: apprt.action.QuitTimer,
    ) !void {
        switch (mode) {
            .start => self.startQuitTimer(),
            .stop => self.stopQuitTimer(),
        }
    }

    pub fn presentTerminal(
        target: apprt.Target,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.present();
                break :surface true;
            },
        };
    }

    pub fn progressReport(
        target: apprt.Target,
        value: terminal.osc.Command.ProgressReport,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.setProgressReport(value);
                break :surface true;
            },
        };
    }

    pub fn promptTitle(target: apprt.Target, value: apprt.action.PromptTitle) bool {
        switch (value) {
            .surface => switch (target) {
                .app => return false,
                .surface => |v| {
                    v.rt_surface.surface.promptTitle();
                    return true;
                },
            },
            // GTK has no separate window-level title override; the window
            // titlebar follows the active tab, so the closest equivalent
            // is the tab title prompt.
            .tab, .window => {
                switch (target) {
                    .app => return false,
                    .surface => |v| {
                        const surface = v.rt_surface.surface;
                        const tab = ext.getAncestor(
                            Tab,
                            surface.as(gtk.Widget),
                        ) orelse {
                            log.warn("surface is not in a tab, ignoring prompt_tab_title", .{});
                            return false;
                        };
                        tab.promptTabTitle();
                        return true;
                    },
                }
            },
        }
    }

    /// Reload the configuration for the application and propagate it
    /// across the entire application and all terminals.
    pub fn reloadConfig(
        self: *Application,
        target: apprt.Target,
        opts: apprt.action.ReloadConfig,
    ) !void {
        // Tell systemd that reloading has started.
        systemd.notify.reloading();

        // When we exit this function tell systemd that reloading has finished.
        defer systemd.notify.ready();

        // Get our config object.
        const config: *Config = config: {
            // Soft-reloading applies conditional logic to the existing loaded
            // config so we return that as-is (but take a reference).
            if (opts.soft) {
                break :config self.private().config.ref();
            }

            // Hard reload, load a new config completely.
            const alloc = self.allocator();
            var config = try CoreConfig.load(alloc);
            defer config.deinit();
            break :config try .new(alloc, &config);
        };
        defer config.unref();

        // Update the proper target. This will trigger a `config_change`
        // apprt action which will propagate the config properly to our
        // property system.
        switch (target) {
            .app => try self.core().updateConfig(
                self.rt(),
                config.get(),
            ),
            .surface => |core| try core.updateConfig(config.get()),
        }
    }

    pub fn render(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.redraw(),
        }
    }

    pub fn resizeSplit(
        target: apprt.Target,
        value: apprt.action.ResizeSplit,
    ) bool {
        switch (target) {
            .app => {
                log.warn("resize_split to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring resize_split", .{});
                    return false;
                };

                // If the tree has no splits (only one leaf), this action is not performable.
                // This allows the key event to pass through to the terminal.
                if (!tree.getIsSplit()) return false;

                return tree.resize(
                    switch (value.direction) {
                        .up => .up,
                        .down => .down,
                        .left => .left,
                        .right => .right,
                    },
                    value.amount,
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.warn("unable to resize split, out of memory", .{});
                        return false;
                    },
                };
            },
        }
    }

    pub fn ringBell(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setBellRinging(true),
        }
    }

    pub fn scrollbar(
        target: apprt.Target,
        value: apprt.Action.Value(.scrollbar),
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setScrollbar(value),
        }
    }

    pub fn startSearch(target: apprt.Target, value: apprt.action.StartSearch) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(true, value.needle),
        }
    }

    pub fn endSearch(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(false, ""),
        }
    }

    pub fn searchTotal(target: apprt.Target, value: apprt.action.SearchTotal) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchTotal(value.total),
        }
    }

    pub fn searchSelected(target: apprt.Target, value: apprt.action.SearchSelected) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchSelected(value.selected),
        }
    }

    pub fn setTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) void {
        switch (target) {
            .app => log.warn("set_title to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setTitle(value.title),
        }
    }

    pub fn setTabTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) bool {
        switch (target) {
            .app => {
                log.warn("set_tab_title to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tab = ext.getAncestor(
                    Tab,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a tab, ignoring set_tab_title", .{});
                    return false;
                };
                tab.setTitleOverride(if (value.title.len == 0) null else value.title);
                return true;
            },
        }
    }

    pub fn showChildExited(
        target: apprt.Target,
        value: apprt.surface.Message.ChildExited,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.surface.childExited(value),
        };
    }

    pub fn showGtkInspector() void {
        gtk.Window.setInteractiveDebugging(@intFromBool(true));
    }

    pub fn sizeLimit(
        target: apprt.Target,
        value: apprt.action.SizeLimit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                // Note: we ignore the max size currently because we have
                // no mechanism to enforce it.
                const surface = core.rt_surface.surface;
                surface.setMinSize(.{
                    .width = value.min_width,
                    .height = value.min_height,
                });

                return true;
            },
        }
    }

    pub fn toggleFullscreen(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleFullscreen(),
        }
    }

    pub fn toggleQuickTerminal(self: *Application) bool {
        // If we already have a quick terminal window, we just toggle the
        // visibility of it.
        if (getQuickTerminalWindow()) |win| {
            win.toggleVisibility();
            return true;
        }

        // If we don't support quick terminals then we do nothing.
        const priv = self.private();
        if (!priv.winproto.supportsQuickTerminal()) return false;

        // Create our new window as a quick terminal
        const win = gobject.ext.newInstance(Window, .{
            .application = self,
            .@"quick-terminal" = true,
        });
        assert(win.isQuickTerminal());
        initAndShowWindow(self, win, null, .none);
        return true;
    }

    pub fn toggleSplitZoom(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("toggle_split_zoom to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                // TODO: pass surface ID when we have that
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring toggle_split_zoom", .{});
                    return false;
                };

                // If the tree has no splits (only one leaf), this action is not performable.
                // This allows the key event to pass through to the terminal.
                if (!tree.getIsSplit()) return false;

                return surface.as(gtk.Widget).activateAction("split-tree.zoom", null) != 0;
            },
        }
    }

    pub fn showOnScreenKeyboard(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("show_on_screen_keyboard to app is unexpected", .{});
                return false;
            },
            // NOTE: Even though `activateOsk` takes a gdk.Event, it's currently
            // unused by all implementations of `activateOsk` as of GTK 4.18.
            // The commit that introduced the method (ce6aa73c) clarifies that
            // the event *may* be used by other IM backends, but for Linux desktop
            // environments this doesn't matter.
            .surface => |v| return v.rt_surface.surface.showOnScreenKeyboard(null),
        }
    }

    fn getQuickTerminalWindow() ?*Window {
        // Find a quick terminal window.
        const list = gtk.Window.listToplevels();
        defer list.free();
        if (ext.listFind(gtk.Window, list, struct {
            fn find(gtk_win: *gtk.Window) bool {
                const win = gobject.ext.cast(
                    Window,
                    gtk_win,
                ) orelse return false;
                return win.isQuickTerminal();
            }
        }.find)) |w| return gobject.ext.cast(
            Window,
            w,
        ).?;

        return null;
    }

    pub fn toggleMaximize(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleMaximize(),
        }
    }

    pub fn toggleTabOverview(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                window.toggleTabOverview();
                return true;
            },
        }
    }

    pub fn toggleWindowDecorations(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring toggle_window_decorations", .{});
                    return false;
                };

                window.toggleWindowDecorations();
                return true;
            },
        }
    }

    pub fn toggleCommandPalette(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().toggleCommandPalette();
            },
        }
    }

    pub fn controlInspector(target: apprt.Target, value: apprt.Action.Value(.inspector)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().controlInspector(value);
            },
        }
    }

    pub fn commandFinished(target: apprt.Target, value: apprt.Action.Value(.command_finished)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().commandFinished(value);
            },
        }
    }

    pub fn setReadonly(target: apprt.Target, value: apprt.Action.Value(.readonly)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().setReadonly(value);
            },
        }
    }

    /// OSC 7778 from inside the pane (T3339): set or, with empty text, clear
    /// its sticky banner.
    pub fn paneBanner(target: apprt.Target, value: apprt.Action.Value(.pane_banner)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                surface.rt_surface.gobj().setPaneBanner(value.text);
                return true;
            },
        }
    }

    /// `prompt_surface_banner` (T3559; Ctrl+Shift+B, the Mac's Cmd+R): the
    /// Set Pane Banner editor for the pane. A viewer pane has no banner.
    pub fn promptBanner(app: *Application, target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                const s = surface.rt_surface.gobj();
                if (s.isViewer()) return false;
                BannerEditor.open(app.allocator(), s);
                return true;
            },
        }
    }

    /// `toggle_pane_sidebar` (T3557): hide or show the pane sidebar in every
    /// window - the flags are shared, so the target does not matter.
    pub fn togglePaneSidebar(app: *Application) bool {
        PaneSidebar.toggleHidden(app.allocator(), "toggle_pane_sidebar");
        return true;
    }

    /// OSC 7777 from inside the pane (T3339): its activity state.
    pub fn activityState(target: apprt.Target, value: apprt.Action.Value(.activity_state)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                surface.rt_surface.gobj().setActivityState(value);
                return true;
            },
        }
    }

    pub fn keySequence(target: apprt.Target, value: apprt.Action.Value(.key_sequence)) bool {
        switch (target) {
            .app => {
                log.warn("key_sequence action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keySequenceAction(value) catch |err| {
                    log.warn("error handling key_sequence action: {}", .{err});
                };
                return true;
            },
        }
    }

    pub fn keyTable(target: apprt.Target, value: apprt.Action.Value(.key_table)) bool {
        switch (target) {
            .app => {
                log.warn("key_table action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keyTableAction(value) catch |err| {
                    log.warn("error handling key_table action: {}", .{err});
                };
                return true;
            },
        }
    }
};

/// This sets various GTK-related environment variables as necessary
/// given the runtime environment or configuration.
///
/// This must be called BEFORE GTK initialization.
/// Set `GALLIUM_DRIVER=d3d12` before GTK initializes, when this is WSL and
/// nothing chose a driver (T3350; `wslg_gpu.zig` has the rules). Returns
/// whether it was set, so `settleWslgGpuEnv` can take it back out.
fn setWslgGpuEnv() bool {
    if (comptime builtin.os.tag != .linux) return false;
    assert(gtk.isInitialized() == 0);
    const decision = wslg_gpu.decide(.{
        .dxg = dxg: {
            std.fs.accessAbsolute(wslg_gpu.device_path, .{}) catch break :dxg false;
            break :dxg true;
        },
        .gallium_driver = std.posix.getenv(wslg_gpu.env_name),
        .loader_override = std.posix.getenv("MESA_LOADER_DRIVER_OVERRIDE"),
        .always_software = std.posix.getenv("LIBGL_ALWAYS_SOFTWARE"),
    });
    switch (decision) {
        .set => {
            _ = internal_os.setenv(wslg_gpu.env_name, wslg_gpu.driver);
            log.info("wslg: setting " ++ wslg_gpu.env_name ++ "=" ++ wslg_gpu.driver ++ " for the app's GL (" ++ wslg_gpu.device_path ++ " present)", .{});
            return true;
        },
        .user_choice => log.info("wslg: GPU driver left to the environment (" ++ wslg_gpu.env_name ++ "/MESA_LOADER_DRIVER_OVERRIDE/LIBGL_ALWAYS_SOFTWARE set)", .{}),
        .not_wsl => {},
    }
    return false;
}

/// Bring GDK's GL up while our `GALLIUM_DRIVER` is in place - Mesa reads it
/// when the display's EGL initializes and every later context reuses that
/// display - then remove it, so neither a shell nor WebKit's sandboxed web
/// process (which aborts on it, T3410) inherits a choice that was the app's.
fn settleWslgGpuEnv(display: *gdk.Display) void {
    var err_: ?*glib.Error = null;
    if (display.prepareGl(&err_) == 0) {
        if (err_) |err| {
            defer err.free();
            log.warn("wslg: GDK GL did not come up with the d3d12 driver: {s}", .{err.f_message orelse "(unknown)"});
        }
    }
    _ = internal_os.unsetenv(wslg_gpu.env_name);
    log.info("wslg: GDK GL prepared; " ++ wslg_gpu.env_name ++ " removed so child processes do not inherit it", .{});
}

fn setGtkEnv(config: *const CoreConfig) error{NoSpaceLeft}!void {
    assert(gtk.isInitialized() == 0);

    var gdk_debug: struct {
        /// output OpenGL debug information
        opengl: bool = false,
        /// disable GLES, Ghostty can't use GLES
        @"gl-disable-gles": bool = false,
        // GTK's new renderer can cause blurry font when using fractional scaling.
        @"gl-no-fractional": bool = false,
        /// Disabling Vulkan can improve startup times by hundreds of
        /// milliseconds on some systems. We don't use Vulkan so we can just
        /// disable it.
        @"vulkan-disable": bool = false,
    } = .{
        // `gtk-opengl-debug` dumps logs directly to stderr so both must be true
        // to enable OpenGL debugging.
        .opengl = state.logging.stderr and config.@"gtk-opengl-debug",
    };

    var gdk_disable: struct {
        @"gles-api": bool = false,
        /// current gtk implementation for color management is not good enough.
        /// see: https://bugs.kde.org/show_bug.cgi?id=495647
        /// gtk issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/6864
        @"color-mgmt": bool = true,
        /// Disabling Vulkan can improve startup times by hundreds of
        /// milliseconds on some systems. We don't use Vulkan so we can just
        /// disable it.
        vulkan: bool = false,
    } = .{};

    environment: {
        if (gtk_version.runtimeAtLeast(4, 18, 0)) {
            gdk_disable.@"color-mgmt" = false;
        }

        if (gtk_version.runtimeAtLeast(4, 16, 0)) {
            // From gtk 4.16, GDK_DEBUG is split into GDK_DEBUG and GDK_DISABLE.
            // For the remainder of "why" see the 4.14 comment below.
            gdk_disable.@"gles-api" = true;
            gdk_disable.vulkan = true;
            break :environment;
        }
        if (gtk_version.runtimeAtLeast(4, 14, 0)) {
            // We need to export GDK_DEBUG to run on Wayland after GTK 4.14.
            // Older versions of GTK do not support these values so it is safe
            // to always set this. Forwards versions are uncertain so we'll have
            // to reassess...
            //
            // Upstream issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/6589
            gdk_debug.@"gl-disable-gles" = true;
            gdk_debug.@"vulkan-disable" = true;

            if (gtk_version.runtimeUntil(4, 17, 5)) {
                // Removed at GTK v4.17.5
                gdk_debug.@"gl-no-fractional" = true;
            }
            break :environment;
        }

        // Versions prior to 4.14 are a bit of an unknown for Ghostty. It
        // is an environment that isn't tested well and we don't have a
        // good understanding of what we may need to do.
        gdk_debug.@"vulkan-disable" = true;
    }

    {
        var buf: [1024]u8 = undefined;
        var fmt = std.io.fixedBufferStream(&buf);
        const writer = fmt.writer();
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_debug)).@"struct".fields) |field| {
            if (@field(gdk_debug, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = fmt.getWritten();
        log.warn("setting GDK_DEBUG={s}", .{value[0 .. value.len - 1]});
        _ = internal_os.setenv("GDK_DEBUG", value[0 .. value.len - 1 :0]);
    }

    {
        var buf: [1024]u8 = undefined;
        var fmt = std.io.fixedBufferStream(&buf);
        const writer = fmt.writer();
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_disable)).@"struct".fields) |field| {
            if (@field(gdk_disable, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = fmt.getWritten();
        log.warn("setting GDK_DISABLE={s}", .{value[0 .. value.len - 1]});
        _ = internal_os.setenv("GDK_DISABLE", value[0 .. value.len - 1 :0]);
    }
}

fn findActiveWindow(data: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) c_int {
    const window: *gtk.Window = @ptrCast(@alignCast(@constCast(data orelse return -1)));

    // Confusingly, `isActive` returns 1 when active,
    // but we want to return 0 to indicate equality.
    // Abusing integers to be enums and booleans is a terrible idea, C.
    return if (window.isActive() != 0) 0 else -1;
}
