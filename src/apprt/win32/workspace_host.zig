//! Single-window mode's workspace bookkeeping (T3181) - the win32 port of the
//! membership and decision half of Mac `WorkspaceHost`
//! (`macos/Sources/Features/Terminal/WindowMode.swift`, Mac 3f772a2f0).
//! Spec: docs/reference/window-modes.md.
//!
//! In `single` mode every window is a WORKSPACE of one shared top-level
//! window. Each workspace keeps its own `Window` controller; only the HWND is
//! shared. This module answers the questions that decide who has it:
//!
//! - which workspace is ON SHOW (`active`), and the most-recently-shown order
//!   of every other one (`order`: on show first);
//! - whether a controller being built starts PARKED (`startsParked`: all but
//!   the first do - the first loads the window);
//! - what a first presentation does (`present`), what a switch does (`show`),
//!   which neighbour next/previous-tab walks to (`neighbor`), and who takes
//!   the window when the one on show closes (`close`) or the window itself
//!   goes (`windowDidClose`);
//! - the activity the window reports: the most urgent of ALL its workspaces
//!   (`rolledUpActivity`), so a parked workspace waiting on a question is the
//!   window waiting on one.
//!
//! It never touches an HWND. Every call answers with the action the caller
//! performs (surrender/adopt, present its own window, close the physical
//! window), so the whole policy is unit-tested in every app-runtime lane and
//! the Window code that carries it out stays free of policy.
//!
//! Generic over the handle type (`*Window` in the app, an integer in tests);
//! handles are compared by identity.
const std = @import("std");

/// The window's activity, most urgent last (Mac `Ghostty.ActivityState`).
pub const Activity = enum(u2) { idle = 0, busy = 1, needs_input = 2 };

pub fn Host(comptime Handle: type) type {
    return struct {
        const Self = @This();

        /// Every open workspace: the one on show first, then most recently
        /// shown first. A workspace admitted parked joins at the back.
        order: std.ArrayListUnmanaged(Handle) = .empty,
        /// The workspace that has the window; null before any has loaded it
        /// and after the window closed.
        active: ?Handle = null,
        /// The workspace that will load the window, before there is one: the
        /// first controller made while no workspace has it.
        loader: ?Handle = null,
        /// `startsParked` told a controller being built that it loads the
        /// window, and `admit` has not run for it yet.
        loader_reserved: bool = false,

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.order.deinit(alloc);
            self.* = .{};
        }

        // ---- Membership ----------------------------------------------------

        /// Asked by a controller being built, before anything can create its
        /// window: whether it starts parked. All but the first do; the first
        /// loads the window, as a window always has.
        pub fn startsParked(self: *Self) bool {
            if (self.active == null and self.loader == null and !self.loader_reserved) {
                self.loader_reserved = true;
                return false;
            }
            return true;
        }

        /// The controller joins, as `startsParked` told it.
        pub fn admit(self: *Self, alloc: std.mem.Allocator, h: Handle, parked: bool) !void {
            self.removeFromOrder(h);
            try self.order.append(alloc, h);
            if (!parked) {
                self.loader_reserved = false;
                self.loader = h;
            }
        }

        pub fn manages(self: *const Self, h: Handle) bool {
            return self.indexOf(h) != null;
        }

        pub fn count(self: *const Self) usize {
            return self.order.items.len;
        }

        pub fn isParked(self: *const Self, h: Handle) bool {
            if (!self.manages(h)) return false;
            if (self.active) |a| if (a == h) return false;
            if (self.loader) |l| if (l == h) return false;
            return true;
        }

        /// The workspace's window loaded (the loader's, or one promoted after
        /// the window closed under the others). The first to load takes the
        /// window and moves to the front.
        pub fn didLoadWindow(self: *Self, h: Handle) void {
            if (!self.manages(h)) return;
            if (self.loader) |l| if (l == h) {
                self.loader = null;
            };
            if (self.active != null) return;
            self.active = h;
            self.moveToFront(h);
        }

        // ---- Presenting ----------------------------------------------------

        pub const Present = enum {
            /// Not a workspace this host manages: present it as a window.
            not_managed,
            /// Put it on show now (`show`; the caller then carries out the
            /// returned `Switch`).
            show,
            /// It is the loader: present its own window without taking focus.
            own_window_background,
            /// Nothing has the window and nothing is about to: it becomes
            /// the loader and presents its own window in the background.
            promote_background,
            /// Stays parked: lay its content out at the window's size.
            stay_parked,
        };

        /// A new workspace's first presentation (Mac `present`). `activate`:
        /// the open should come forward (a manual open, or `--focus`); a
        /// programmatic open without it stays parked behind the one on show.
        pub fn present(self: *Self, h: Handle, activate: bool) Present {
            if (!self.manages(h)) return .not_managed;
            if (activate) return .show;
            if (!self.isParked(h)) return .own_window_background;
            if (self.active == null and self.loader == null) {
                self.loader = h;
                return .promote_background;
            }
            return .stay_parked;
        }

        pub const Switch = union(enum) {
            /// Not managed: nothing happens.
            refused,
            /// Already on show; raise the window when `make_key`.
            already,
            /// No window yet: `h` presents its own window (it is, or now
            /// becomes, the loader).
            own_window,
            /// No window yet and another workspace is loading it: that one
            /// presents first, then `show` is asked again.
            load_first: Handle,
            /// The hand-off: `from` surrenders the window, `to` adopts it.
            hand_off: struct { from: Handle, to: Handle },
        };

        /// Put `h` on show (Mac `show`). The caller performs the returned
        /// action; on `hand_off` the bookkeeping has already moved. Refusal
        /// while a modal is up on the window is the caller's (it owns the
        /// window); a refused switch must not call this.
        pub fn show(self: *Self, h: Handle) Switch {
            if (!self.manages(h)) return .refused;
            const from = self.active orelse {
                if (self.isParked(h)) {
                    if (self.loader) |l| if (l != h) return .{ .load_first = l };
                    self.loader = h;
                }
                return .own_window;
            };
            if (from == h) return .already;
            self.active = h;
            self.moveToFront(h);
            return .{ .hand_off = .{ .from = from, .to = h } };
        }

        /// The workspace `offset` places from the one on show in `sidebar`
        /// (the sidebar's order), wrapping - next/previous tab, goto_window.
        pub fn neighbor(self: *const Self, offset: isize, sidebar: []const Handle) ?Handle {
            const a = self.active orelse return null;
            if (sidebar.len < 2) return null;
            const i = for (sidebar, 0..) |s, idx| {
                if (s == a) break idx;
            } else return null;
            const n: isize = @intCast(sidebar.len);
            const at: isize = @mod(@as(isize, @intCast(i)) + offset, n);
            return sidebar[@intCast(at)];
        }

        // ---- Closing -------------------------------------------------------

        pub const Close = union(enum) {
            /// Not a workspace this host manages: close it as a window.
            not_managed,
            /// A parked workspace: it closes in place, the window untouched.
            in_place,
            /// The one on show: `next` (the most recently shown other) adopts
            /// the window first, then this one closes in place.
            hand_to: Handle,
            /// The last workspace: the window closes with it.
            close_window,
        };

        /// Close a workspace (Mac `close`). The one on show hands the window
        /// to the next most recently shown; the last one closes the window.
        pub fn close(self: *Self, h: Handle) Close {
            if (!self.manages(h)) return .not_managed;
            const has_window = blk: {
                if (self.active) |a| if (a == h) break :blk true;
                break :blk false;
            };
            if (has_window) {
                const next = for (self.order.items) |o| {
                    if (o != h) break o;
                } else {
                    // The window goes with it; `windowDidClose` then drops it.
                    return .close_window;
                };
                self.active = next;
                self.moveToFront(next);
                self.drop(h);
                return .{ .hand_to = next };
            }
            self.drop(h);
            return .in_place;
        }

        /// The window itself closed with `h` on show. Every other workspace
        /// is still open: the most recently shown one is returned to load a
        /// window of its own (null at quit, or when none is left).
        pub fn windowDidClose(self: *Self, h: Handle, quitting: bool) ?Handle {
            const was_active = if (self.active) |a| a == h else true;
            self.drop(h);
            if (!was_active) return null;
            self.active = null;
            if (quitting) return null;
            if (self.order.items.len == 0) return null;
            const next = self.order.items[0];
            self.loader = next;
            return next;
        }

        // ---- Activity ------------------------------------------------------

        /// The most urgent activity of every workspace (Mac
        /// `refreshWindowActivity`): `state(h)` is each one's own.
        pub fn rolledUpActivity(self: *const Self, ctx: anytype, comptime state: fn (@TypeOf(ctx), Handle) Activity) Activity {
            var worst: Activity = .idle;
            for (self.order.items) |h| {
                const s = state(ctx, h);
                if (@intFromEnum(s) > @intFromEnum(worst)) worst = s;
            }
            return worst;
        }

        // ---- internals -----------------------------------------------------

        fn indexOf(self: *const Self, h: Handle) ?usize {
            for (self.order.items, 0..) |o, i| if (o == h) return i;
            return null;
        }

        fn moveToFront(self: *Self, h: Handle) void {
            const i = self.indexOf(h) orelse return;
            if (i == 0) return;
            const items = self.order.items;
            std.mem.copyBackwards(Handle, items[1 .. i + 1], items[0..i]);
            items[0] = h;
        }

        fn removeFromOrder(self: *Self, h: Handle) void {
            if (self.indexOf(h)) |i| _ = self.order.orderedRemove(i);
        }

        fn drop(self: *Self, h: Handle) void {
            self.removeFromOrder(h);
            if (self.loader) |l| if (l == h) {
                self.loader = null;
            };
            if (self.active) |a| if (a == h) {
                self.active = null;
            };
        }
    };
}

// ---- tests (pure; every lane) ----------------------------------------------

const testing = std.testing;
const H = Host(u32);

fn openAndLoad(host: *H, id: u32) !void {
    const parked = host.startsParked();
    try host.admit(testing.allocator, id, parked);
    if (!parked) host.didLoadWindow(id);
}

test "workspace_host: the first controller loads the window, every later one starts parked" {
    var host: H = .{};
    defer host.deinit(testing.allocator);

    try testing.expect(!host.startsParked());
    // A second controller built before the first is admitted still parks:
    // the window is reserved for the first.
    try testing.expect(host.startsParked());
    try host.admit(testing.allocator, 1, false);
    try testing.expect(!host.isParked(1));
    host.didLoadWindow(1);
    try testing.expectEqual(@as(?u32, 1), host.active);

    try testing.expect(host.startsParked());
    try host.admit(testing.allocator, 2, true);
    try testing.expect(host.isParked(2));
    try testing.expectEqual(@as(?u32, 1), host.active);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, host.order.items);
}

test "workspace_host: focus policy - a manual open shows, a programmatic one stays parked" {
    var host: H = .{};
    defer host.deinit(testing.allocator);
    try openAndLoad(&host, 1);
    try testing.expectEqual(H.Present.own_window_background, host.present(1, false));

    try openAndLoad(&host, 2);
    // `+new-window` without --focus: parked, the one on show keeps the window.
    try testing.expectEqual(H.Present.stay_parked, host.present(2, false));
    try testing.expectEqual(@as(?u32, 1), host.active);

    try openAndLoad(&host, 3);
    // Ctrl+Shift+N, the + button, --focus: on show.
    try testing.expectEqual(H.Present.show, host.present(3, true));
    const sw = host.show(3);
    try testing.expectEqual(@as(u32, 1), sw.hand_off.from);
    try testing.expectEqual(@as(u32, 3), sw.hand_off.to);
    try testing.expectEqual(@as(?u32, 3), host.active);
    try testing.expect(host.isParked(1));
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, host.order.items);

    try testing.expectEqual(H.Present.not_managed, host.present(99, true));
}

test "workspace_host: switching keeps a most-recently-shown order; showing the one on show is a no-op" {
    var host: H = .{};
    defer host.deinit(testing.allocator);
    try openAndLoad(&host, 1);
    try openAndLoad(&host, 2);
    try openAndLoad(&host, 3);

    _ = host.show(2);
    _ = host.show(3);
    try testing.expectEqualSlices(u32, &.{ 3, 2, 1 }, host.order.items);
    try testing.expectEqual(H.Switch.already, host.show(3));
    try testing.expectEqual(H.Switch.refused, host.show(42));
}

test "workspace_host: next and previous walk the sidebar's order and wrap" {
    var host: H = .{};
    defer host.deinit(testing.allocator);
    try openAndLoad(&host, 1);
    try openAndLoad(&host, 2);
    try openAndLoad(&host, 3);
    const sidebar = [_]u32{ 1, 2, 3 };
    try testing.expectEqual(@as(?u32, 2), host.neighbor(1, &sidebar));
    try testing.expectEqual(@as(?u32, 3), host.neighbor(-1, &sidebar));
    _ = host.show(3);
    try testing.expectEqual(@as(?u32, 1), host.neighbor(1, &sidebar));
    try testing.expectEqual(@as(?u32, 2), host.neighbor(-1, &sidebar));
    try testing.expectEqual(@as(?u32, 3), host.neighbor(3, &sidebar));
    // One workspace has no neighbour.
    try testing.expectEqual(@as(?u32, null), host.neighbor(1, &.{3}));
}

test "workspace_host: closing the one on show hands the window to the one shown before it" {
    var host: H = .{};
    defer host.deinit(testing.allocator);
    try openAndLoad(&host, 1);
    try openAndLoad(&host, 2);
    try openAndLoad(&host, 3);
    _ = host.show(3);
    _ = host.show(2); // order: 2, 3, 1

    // A parked workspace closes in place; the window is untouched.
    try testing.expectEqual(H.Close.in_place, host.close(1));
    try testing.expectEqual(@as(?u32, 2), host.active);

    // The one on show hands the window to the most recently shown other.
    try testing.expectEqual(@as(u32, 3), host.close(2).hand_to);
    try testing.expectEqual(@as(?u32, 3), host.active);
    try testing.expectEqualSlices(u32, &.{3}, host.order.items);

    // The last one closes the window; its windowDidClose then drops it.
    try testing.expectEqual(H.Close.close_window, host.close(3));
    try testing.expectEqual(@as(?u32, null), host.windowDidClose(3, false));
    try testing.expectEqual(@as(usize, 0), host.count());
    try testing.expectEqual(H.Close.not_managed, host.close(3));

    // And with nothing left, the next controller loads a window again.
    try testing.expect(!host.startsParked());
}

test "workspace_host: the window closing under parked workspaces promotes the most recent one" {
    var host: H = .{};
    defer host.deinit(testing.allocator);
    try openAndLoad(&host, 1);
    try openAndLoad(&host, 2);
    try openAndLoad(&host, 3);
    _ = host.show(3); // order: 3, 1, 2

    try testing.expectEqual(@as(?u32, 1), host.windowDidClose(3, false));
    try testing.expectEqual(@as(?u32, null), host.active);
    try testing.expectEqual(@as(?u32, 1), host.loader);
    try testing.expect(!host.isParked(1));
    try testing.expect(host.isParked(2));
    // The promoted one loads its window and takes it.
    host.didLoadWindow(1);
    try testing.expectEqual(@as(?u32, 1), host.active);
    try testing.expectEqual(@as(?u32, null), host.loader);

    // At quit nothing is promoted.
    try testing.expectEqual(@as(?u32, null), host.windowDidClose(1, true));
    try testing.expectEqual(@as(?u32, null), host.loader);
}

test "workspace_host: show with no window yet - the loader presents first" {
    var host: H = .{};
    defer host.deinit(testing.allocator);
    // Restore builds every controller before any window has loaded.
    try testing.expect(!host.startsParked());
    try host.admit(testing.allocator, 1, false);
    try testing.expect(host.startsParked());
    try host.admit(testing.allocator, 2, true);

    try testing.expectEqual(@as(u32, 1), host.show(2).load_first);
    host.didLoadWindow(1);
    const sw = host.show(2);
    try testing.expectEqual(@as(u32, 2), sw.hand_off.to);

    // A lone parked workspace with no window and no loader becomes the loader.
    var lone: H = .{};
    defer lone.deinit(testing.allocator);
    try lone.admit(testing.allocator, 7, true);
    try testing.expectEqual(H.Switch.own_window, lone.show(7));
    try testing.expectEqual(@as(?u32, 7), lone.loader);
    var bg: H = .{};
    defer bg.deinit(testing.allocator);
    try bg.admit(testing.allocator, 8, true);
    try testing.expectEqual(H.Present.promote_background, bg.present(8, false));
}

test "workspace_host: the window reports the most urgent activity of every workspace" {
    var host: H = .{};
    defer host.deinit(testing.allocator);
    try openAndLoad(&host, 1);
    try openAndLoad(&host, 2);
    try openAndLoad(&host, 3);
    const States = struct {
        s: [4]Activity,
        fn get(self: *const @This(), h: u32) Activity {
            return self.s[h];
        }
    };
    var st: States = .{ .s = .{ .idle, .idle, .idle, .idle } };
    try testing.expectEqual(Activity.idle, host.rolledUpActivity(&st, States.get));
    st.s[3] = .busy;
    try testing.expectEqual(Activity.busy, host.rolledUpActivity(&st, States.get));
    // A parked workspace waiting on a question is the window waiting on one.
    st.s[2] = .needs_input;
    try testing.expect(host.isParked(2));
    try testing.expectEqual(Activity.needs_input, host.rolledUpActivity(&st, States.get));
}
