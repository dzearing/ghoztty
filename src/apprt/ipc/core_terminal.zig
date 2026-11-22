//! `verbs.zig`'s `Terminal` over the shared core `Surface` (T3361). Both the
//! win32 and the GTK frontend host one core Surface per terminal pane, so the
//! pty writes and the screen dump the shared verbs need are written once
//! here instead of once per frontend.
//!
//! Not imported by the none-lane tests: it pulls in the whole core Surface.
//! The verb logic it serves is tested over a fake in `verbs.zig`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const CoreSurface = @import("../../Surface.zig");
const terminal = @import("../../terminal/main.zig");
const verbs = @import("verbs.zig");

pub const CoreTerminal = struct {
    core: *CoreSurface,

    /// Respects a read-only pane, as every input path does.
    pub fn writeRaw(self: CoreTerminal, bytes: []const u8) !void {
        return self.core.writePtyRaw(bytes);
    }

    pub fn writeBracketed(self: CoreTerminal, bytes: []const u8) !void {
        return self.core.writePtyBracketed(bytes);
    }

    pub fn pasteIsBracketed(self: CoreTerminal) bool {
        return self.core.pasteIsBracketed();
    }

    /// The whole screen (scrollback + active) as plain text, the Mac's
    /// full-SCREEN `ghostty_surface_read_text` selection, as laid out (no
    /// TUI reflow, main d886ba4b5). Null when it cannot be serialized at all.
    pub fn dumpScreen(self: CoreTerminal, arena: Allocator, timing: ?*verbs.DumpTiming) ?[]const u8 {
        const core = self.core;
        const t_enter: ?std.time.Instant = if (timing != null) (std.time.Instant.now() catch null) else null;
        // PRIORITY (T114): every frontend calls this on its UI thread, so
        // losing lock races here freezes the window - measured at 23628 ms of
        // lock wait for 45 ms of work before the fairness ticket existed.
        core.renderer_state.lockPriority();
        defer core.renderer_state.unlockPriority();
        const t_locked: ?std.time.Instant = if (timing != null) (std.time.Instant.now() catch null) else null;
        defer if (timing) |tm| record: {
            const enter = t_enter orelse break :record;
            const locked = t_locked orelse break :record;
            const now = std.time.Instant.now() catch break :record;
            tm.lock_wait_ns = locked.since(enter);
            tm.dump_ns = now.since(locked);
        };

        const pages = &core.io.terminal.screens.active.pages;
        const tl = pages.getTopLeft(.screen);
        const br = pages.getBottomRight(.screen) orelse return null;
        const sel = terminal.Selection.init(tl, br, false);
        const text = core.dumpTextLocked(arena, sel, false) catch return null;
        return text.text;
    }
};
