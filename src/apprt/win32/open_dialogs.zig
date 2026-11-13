//! Which modal dialogs are open right now, and over which window (T2938).
//!
//! `ConfirmDialog` runs its own nested message pump, and IPC requests are
//! dispatched from inside it. So a `ghoztty +close` can arrive while the
//! window it names is sitting under a "Processes are still running in this
//! window. Close anyway?" prompt - the win32 counterpart of the Mac's
//! `attachedSheet`. Mac answers that `+close` with "waiting on a close
//! confirmation" (4b558ab8f) and `+close --force` dismisses the sheet first;
//! this stack is how the win32 server can ask the same question and give the
//! same two answers.
//!
//! Pure on purpose: the nodes live on the dialogs' own stack frames (one per
//! nested modal loop, innermost on top), owners are compared as plain
//! integers, and "which top-level window owns this HWND" is passed in, so the
//! bookkeeping is unit tested in the none lane without a desktop.

const std = @import("std");

/// One open dialog. `owner` is its owner HWND as an integer (0 for an
/// ownerless dialog, which no window claims). `dismiss` answers it with its
/// dismissive result the next time its pump looks.
pub const Node = struct {
    prev: ?*Node = null,
    owner: usize,
    ctx: *anyopaque,
    dismiss: *const fn (ctx: *anyopaque) void,
};

pub const Stack = struct {
    top: ?*Node = null,

    pub fn push(self: *Stack, node: *Node) void {
        node.prev = self.top;
        self.top = node;
    }

    /// Remove `node` wherever it sits. Modal loops nest, so it is normally
    /// the top; a node that is not on the stack is left alone.
    pub fn remove(self: *Stack, node: *Node) void {
        var link: *?*Node = &self.top;
        while (link.*) |n| {
            if (n == node) {
                link.* = n.prev;
                n.prev = null;
                return;
            }
            link = &n.prev;
        }
    }

    /// How many open dialogs belong to the top-level window `root`: owned by
    /// it directly, or by a window whose root (`rootOf`) is it.
    pub fn countOver(self: *const Stack, root: usize, rootOf: *const fn (usize) usize) usize {
        if (root == 0) return 0;
        var n: usize = 0;
        var it = self.top;
        while (it) |node| : (it = node.prev) {
            if (owns(node.owner, root, rootOf)) n += 1;
        }
        return n;
    }

    /// Dismiss every open dialog over `root`; returns how many. Each one's
    /// pump sees the answer when control returns to it, innermost first.
    pub fn dismissOver(self: *Stack, root: usize, rootOf: *const fn (usize) usize) usize {
        if (root == 0) return 0;
        var n: usize = 0;
        var it = self.top;
        while (it) |node| : (it = node.prev) {
            if (owns(node.owner, root, rootOf)) {
                node.dismiss(node.ctx);
                n += 1;
            }
        }
        return n;
    }
};

fn owns(owner: usize, root: usize, rootOf: *const fn (usize) usize) bool {
    if (owner == 0) return false;
    return owner == root or rootOf(owner) == root;
}

const testing = std.testing;

/// Test topology: windows 100 and 200 are top-level; 101 is a child of 100.
fn testRoot(h: usize) usize {
    return switch (h) {
        101 => 100,
        else => h,
    };
}

const Probe = struct {
    dismissed: u32 = 0,
    fn hit(ctx: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.dismissed += 1;
    }
};

test "open_dialogs: a dialog counts over the window that owns it, directly or through a child" {
    var stack: Stack = .{};
    var p: Probe = .{};
    var a: Node = .{ .owner = 100, .ctx = &p, .dismiss = Probe.hit };
    var b: Node = .{ .owner = 101, .ctx = &p, .dismiss = Probe.hit };
    stack.push(&a);
    stack.push(&b);
    try testing.expectEqual(@as(usize, 2), stack.countOver(100, testRoot));
    try testing.expectEqual(@as(usize, 0), stack.countOver(200, testRoot));
    // An ownerless dialog and an absent window match nothing.
    var c: Node = .{ .owner = 0, .ctx = &p, .dismiss = Probe.hit };
    stack.push(&c);
    try testing.expectEqual(@as(usize, 0), stack.countOver(0, testRoot));
    try testing.expectEqual(@as(usize, 2), stack.countOver(100, testRoot));
}

test "open_dialogs: dismissOver answers only that window's dialogs" {
    var stack: Stack = .{};
    var mine: Probe = .{};
    var other: Probe = .{};
    var a: Node = .{ .owner = 100, .ctx = &mine, .dismiss = Probe.hit };
    var b: Node = .{ .owner = 200, .ctx = &other, .dismiss = Probe.hit };
    stack.push(&a);
    stack.push(&b);
    try testing.expectEqual(@as(usize, 1), stack.dismissOver(100, testRoot));
    try testing.expectEqual(@as(u32, 1), mine.dismissed);
    try testing.expectEqual(@as(u32, 0), other.dismissed);
}

test "open_dialogs: remove unlinks a node from anywhere and ignores a stranger" {
    var stack: Stack = .{};
    var p: Probe = .{};
    var a: Node = .{ .owner = 100, .ctx = &p, .dismiss = Probe.hit };
    var b: Node = .{ .owner = 100, .ctx = &p, .dismiss = Probe.hit };
    var stranger: Node = .{ .owner = 100, .ctx = &p, .dismiss = Probe.hit };
    stack.push(&a);
    stack.push(&b);
    stack.remove(&stranger);
    try testing.expectEqual(@as(usize, 2), stack.countOver(100, testRoot));
    stack.remove(&a); // the outer one, under b
    try testing.expectEqual(@as(usize, 1), stack.countOver(100, testRoot));
    try testing.expectEqual(&b, stack.top.?);
    stack.remove(&b);
    try testing.expect(stack.top == null);
}
