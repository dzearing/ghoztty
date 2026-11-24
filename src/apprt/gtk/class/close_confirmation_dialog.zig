const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");
const adw = @import("adw");
const adw_version = @import("../adw_version.zig");

const gresource = @import("../build/gresource.zig");
const i18n = @import("../../../os/main.zig").i18n;
const Common = @import("../class.zig").Common;
const Dialog = @import("dialog.zig").Dialog;
const disconnect_offer = @import("../disconnect_offer.zig");

const log = std.log.scoped(.gtk_ghostty_close_confirmation_dialog);

pub const CloseConfirmationDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = Dialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCloseConfirmationDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const target = struct {
            pub const name = "target";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                Target,
                .{
                    .default = .app,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "target",
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        /// The user chose **Disconnect** (T3563): close it, but leave its
        /// remote sessions running. Only emitted after `offerDisconnect`.
        pub const @"disconnect-request" = struct {
            pub const name = "disconnect-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        pub const cancel = struct {
            pub const name = "cancel";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        target: Target,
        /// Set by `offerDisconnect`: the dialog asks Disconnect / Close /
        /// Cancel and says where the sessions run instead of `Target.body`.
        disconnect: bool = false,
        disconnect_body: [disconnect_offer.body_cap]u8 = undefined,
        disconnect_body_len: usize = 0,
        /// A response was handled: any later one (the close-response a
        /// dismissal can add after `answer`) is ignored.
        answered: bool = false,
        pub var offset: c_int = 0;
    };

    pub fn new(target: Target) *Self {
        return gobject.ext.newInstance(Self, .{
            .target = target,
        });
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        // Setup our title/body text.
        const priv = self.private();
        self.as(Dialog.Parent).setHeading(priv.target.title());
        self.as(Dialog.Parent).setBody(self.bodyText());

        // Show it
        self.as(Dialog).present(parent);
    }

    /// Offer **Disconnect** (T3563, Mac `SessionDisconnectPolicy`): a third
    /// button, rightmost and the default (Return picks it), that closes
    /// locally and leaves the remote sessions `offer` counted running. The
    /// body becomes the shared scope-neutral wording naming the machine.
    /// Call before `present`.
    pub fn offerDisconnect(self: *Self, offer: disconnect_offer.Offer) void {
        const priv = self.private();
        const body = offer.body(&priv.disconnect_body);
        priv.disconnect_body_len = body.len;
        priv.disconnect = true;
        const d = self.as(Dialog.Parent);
        d.addResponse("disconnect", i18n._("Disconnect"));
        d.setResponseAppearance("disconnect", .suggested);
        d.setDefaultResponse("disconnect");
    }

    /// The body the dialog shows (the test seam reads it).
    pub fn bodyText(self: *Self) [*:0]const u8 {
        const priv = self.private();
        if (priv.disconnect) return priv.disconnect_body[0..priv.disconnect_body_len :0];
        return priv.target.body();
    }

    /// Whether this dialog offers Disconnect (the test seam reads it).
    pub fn offersDisconnect(self: *Self) bool {
        return self.private().disconnect;
    }

    /// Answer the dialog as if the user pressed `response_id` (`"close"`,
    /// `"disconnect"`, `"cancel"`). The DEBUG-ONLY `close-dialog` seam drives
    /// this: Wayland gives a test no input to press a button with. The dialog
    /// is dismissed FIRST, while the widget it was presented on still exists:
    /// a tab's answer removes that tab, and a dialog closed after its parent
    /// left the window stays in the window's dialog stack, where it swallows
    /// the window's next close request.
    pub fn answer(self: *Self, response_id: [*:0]const u8) void {
        _ = self.ref();
        defer self.unref();
        const priv = self.private();
        if (priv.answered) return;
        priv.answered = true; // the close below must not answer it first
        // libadwaita's own close (Escape's path), not a forced one.
        if (comptime adw_version.supportsDialogs()) {
            _ = self.as(adw.Dialog).close();
        } else self.close();
        self.dispatch(response_id);
    }

    pub fn close(self: *Self) void {
        self.as(Dialog).close();
    }

    fn response(
        self: *Self,
        response_id: [*:0]const u8,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.answered) return;
        priv.answered = true;
        self.dispatch(response_id);
    }

    fn dispatch(self: *Self, response_id: [*:0]const u8) void {
        if (std.mem.orderZ(u8, response_id, "disconnect") == .eq) {
            signals.@"disconnect-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
        } else if (std.mem.orderZ(u8, response_id, "close") == .eq) {
            signals.@"close-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
        } else {
            signals.cancel.impl.emit(
                self,
                null,
                .{},
                null,
            );
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
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
            gobject.ext.ensureType(Dialog);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 2,
                    .name = "close-confirmation-dialog",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.target.impl,
            });

            // Signals
            signals.@"close-request".impl.register(.{});
            signals.@"disconnect-request".impl.register(.{});
            signals.cancel.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            Dialog.virtual_methods.response.implement(class, &response);
        }

        pub const as = C.Class.as;
    };
};

/// The target of a close dialog.
///
/// This is here so that we can consolidate all logic related to
/// prompting the user and closing windows/tabs/surfaces/etc.
/// together into one struct that is the sole source of truth.
pub const Target = enum(c_int) {
    app,
    tab,
    window,
    surface,

    pub fn title(self: Target) [*:0]const u8 {
        return switch (self) {
            .app => i18n._("Quit Ghostty?"),
            .tab => i18n._("Close Tab?"),
            .window => i18n._("Close Window?"),
            .surface => i18n._("Close Split?"),
        };
    }

    pub fn body(self: Target) [*:0]const u8 {
        return switch (self) {
            .app => i18n._("All terminal sessions will be terminated."),
            .tab => i18n._("All terminal sessions in this tab will be terminated."),
            .window => i18n._("All terminal sessions in this window will be terminated."),
            .surface => i18n._("The currently running process in this split will be terminated."),
        };
    }

    pub const getGObjectType = gobject.ext.defineEnum(
        Target,
        .{ .name = "GhosttyCloseConfirmationDialogTarget" },
    );
};
