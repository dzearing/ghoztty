const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const adw_version = @import("../adw_version.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_dialog);

/// Dialog is a simple abstraction over the `adw.AlertDialog` and
/// `adw.MessageDialog` widgets, chosen at comptime based on the linked
/// Adwaita version.
///
/// Once we drop support for Adwaita <= 1.2, this can be fully removed
/// and we can use `adw.AlertDialog` directly.
pub const Dialog = extern struct {
    const Self = @This();
    parent_instance: Parent,

    pub const Parent = if (adw_version.supportsDialogs())
        adw.AlertDialog
    else
        adw.MessageDialog;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyDialog",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub const virtual_methods = struct {
        /// Forwarded from parent so subclasses can reference this
        /// directly. This will make it easier to remove Dialog in the future.
        pub const response = Parent.virtual_methods.response;
    };

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        switch (Parent) {
            adw.AlertDialog => self.as(adw.Dialog).present(parent),

            adw.MessageDialog => {
                // Reset the previous parent window
                self.as(gtk.Window).setTransientFor(null);

                // We need to get the window for the parent in order
                // to set the transient-for property on the MessageDialog.
                if (parent) |widget| parent: {
                    const root = gtk.Widget.getRoot(widget) orelse break :parent;
                    const window = gobject.ext.cast(
                        gtk.Window,
                        root,
                    ) orelse break :parent;
                    self.as(gtk.Window).setTransientFor(window);
                }

                self.as(gtk.Window).present();
            },

            else => comptime unreachable,
        }
    }

    pub fn close(self: *Self) void {
        switch (Parent) {
            adw.AlertDialog => CloseRetry.close(self.as(adw.Dialog)),
            adw.MessageDialog => self.as(gtk.Window).close(),
            else => comptime unreachable,
        }
    }

    /// T3677: `adw_dialog_force_close` is silently a no-op on a dialog
    /// that has not finished presenting. libadwaita (1.5) opens a
    /// presented dialog's sheet only on the dialog's SECOND frame tick
    /// (`map_tick_cb`); until then the sheet is not open, so
    /// `set_open(FALSE)` returns early, nothing emits `closed`, and the
    /// tick then opens the sheet anyway - the answered dialog stays up
    /// and the window's next close request is spent dismissing it. A
    /// headless compositor that ticks slowly hits that every time; a
    /// fast Cancel/Escape on a real screen can too. So: close, and if no
    /// `closed` came out of it, close again on each frame until one does.
    const CloseRetry = struct {
        dialog: *adw.Dialog,
        closed: bool = false,
        ticks: u32 = 0,

        /// Bounded: a dialog that never closes stops being asked.
        const max_ticks: u32 = 240;

        fn close(dialog: *adw.Dialog) void {
            const alloc = std.heap.c_allocator;
            const self = alloc.create(CloseRetry) catch {
                dialog.forceClose();
                return;
            };
            self.* = .{ .dialog = dialog };
            // Held across the close: with animations off the sheet closes
            // synchronously and the host may drop its ref before we return.
            _ = dialog.as(gobject.Object).ref();
            defer dialog.as(gobject.Object).unref();
            _ = adw.Dialog.signals.closed.connect(dialog, *CloseRetry, onClosed, self, .{});
            dialog.forceClose();
            if (self.closed) return destroy(self);
            log.info("dialog close deferred: not presented yet, retrying each frame", .{});
            _ = dialog.as(gtk.Widget).addTickCallback(&tick, self, &destroy);
        }

        fn onClosed(_: *adw.Dialog, self: *CloseRetry) callconv(.c) void {
            self.closed = true;
        }

        fn tick(widget: *gtk.Widget, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
            const self: *CloseRetry = @ptrCast(@alignCast(data orelse return 0));
            if (self.closed) return 0;
            // Unrooted: it left its host some other way.
            if (widget.getRoot() == null) return 0;
            self.ticks += 1;
            if (self.ticks > max_ticks) {
                log.warn("dialog close: still open after {d} frames, giving up", .{max_ticks});
                return 0;
            }
            self.dialog.forceClose();
            return @intFromBool(!self.closed);
        }

        fn destroy(data: ?*anyopaque) callconv(.c) void {
            const self: *CloseRetry = @ptrCast(@alignCast(data orelse return));
            // Matched on data, so a handler the dialog's dispose already
            // dropped is no warning.
            _ = gobject.signalHandlersDisconnectMatched(
                self.dialog.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
            std.heap.c_allocator.destroy(self);
        }
    };

    const C = Common(Self, null);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            _ = class;
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
