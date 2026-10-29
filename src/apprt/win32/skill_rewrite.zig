//! The Windows wording of the bundled `ghoztty` skill (T1327).
//!
//! `assets/ghoztty/skills/ghoztty/` (`SKILL.md` and its reference files) is
//! byte-identical to the Mac bundle resource (`test/win32/hook-json.ps1`
//! section A), and it is written from the Mac seat: trackpad gestures, Cmd chords, `/bin/zsh`. Shipped as-is,
//! an agent on a Windows PC repeats those instructions to the person in front
//! of it. So the Windows app rewrites the handful of Mac-only phrases as it
//! INSTALLS the skill, and the asset itself stays a copy rather than a fork —
//! re-vendoring from main is still a file copy, never a hand merge.
//!
//! Each row is an exact phrase of the shared document and the sentence that is
//! true of the Windows build. A row whose phrase no longer occurs (main
//! reworded the paragraph) does nothing at install time, and the
//! "every rewrite still matches" test below goes red, so a re-vendor that moves
//! the text is loud instead of silently shipping the Mac wording again. The
//! "no Mac wording survives" test is the other half: a NEW Mac-only phrase
//! arriving with a re-vendor fails it until it gets a row.
//!
//! The facts each replacement states, and where they are pinned:
//!   - image zoom/pan: `viewer_image.zig` + `src/viewer/image.js` (a touchpad
//!     pinch arrives as ctrl+wheel), keyboard zoom `viewer_accel.zoomAction`
//!   - ctrl+r reload, ctrl+f find: `viewer_accel.paneChord`
//!   - ctrl+shift+b banner editor, ctrl+enter saves: `Config.zig` win32 block,
//!     `BannerDialog.zig`
//!   - ctrl+shift+n New Remote Window: `window_chord.zig`
//!   - banner link Ctrl / Ctrl+Shift: `banner_link.clickAction`
//!   - per-flavor `--shell` invocation, `cmd.exe` fallback: `docs/claude/cli.md`
//!   - `+rearrange` undo on ctrl+shift+z: `LayoutUndo.zig` (T2234), chord in
//!     the `Config.zig` win32 block
//!
//! No OS imports, so the tests run in every app-runtime lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rewrite = struct {
    /// An exact phrase of the shared (Mac-worded) document.
    mac: []const u8,
    /// What the Windows install says instead.
    win: []const u8,
};

pub const windows_rewrites = [_]Rewrite{
    // `+new-window` and `+split` option tables.
    .{
        .mac = "| `--shell=<path>` | Shell to use for `--command`/`--split-command`, invoked with `-lic`. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`. |",
        .win = "| `--shell=<path>` | Shell to use for `--command`/`--split-command`, kept alive after the command per flavor: `pwsh`/`powershell` `-NoExit -Command`, `cmd` `/K`, `wsl` `-e /bin/sh -lic`, anything else (e.g. git-bash) `-lic`. Falls back to config `command-shell`, then `cmd.exe`. |",
    },
    .{
        .mac = "| `--shell=<path>` | Shell to use for `--command`, invoked with `-lic`. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`. |",
        .win = "| `--shell=<path>` | Shell to use for `--command`, kept alive after the command per flavor: `pwsh`/`powershell` `-NoExit -Command`, `cmd` `/K`, `wsl` `-e /bin/sh -lic`, anything else (e.g. git-bash) `-lic`. Falls back to config `command-shell`, then `cmd.exe`. |",
    },
    // Image viewer gestures.
    .{
        .mac = "trackpad pinch-to-zoom, two-finger pan with elastic\n  edges, and double-click (or two-finger double-tap) to toggle",
        .win = "touchpad pinch or Ctrl+wheel to zoom (Ctrl+= / Ctrl+- /\n  Ctrl+0 from the keyboard), scroll or touchpad to pan, and double-click to toggle",
    },
    .{
        .mac = "**Cmd-F is\n  declined** in an image pane",
        .win = "**Ctrl+F\n  finds nothing** in an image pane",
    },
    // Viewer reload.
    .{ .mac = "`+reload`/Cmd+R re-runs it", .win = "`+reload`/Ctrl+R re-runs it" },
    // `+rearrange`.
    .{
        .mac = "- Supports undo (Cmd+Z restores the previous layout).",
        .win = "- Supports undo (Ctrl+Shift+Z restores the previous layout).",
    },
    // Banner editor.
    .{
        .mac = "Interactive users can press Cmd+R (\"Set Pane Banner…\", also in the command palette) for a multi-line editor (Return = newline, Cmd+Return = save).",
        .win = "Interactive users can press Ctrl+Shift+B (\"Set Pane Banner…\", also in the command palette) for a multi-line editor (Enter = newline, Ctrl+Enter = save).",
    },
    // `+new-remote-window`.
    .{
        .mac = "Same flow as the Cmd-Shift-N \"New Remote Window\" menu action.",
        .win = "Same flow as the Ctrl+Shift+N \"New Remote Window\" menu action.",
    },
    .{
        .mac = "(e.g. `wsl.exe`, `powershell.exe`, `/bin/zsh`)",
        .win = "(e.g. `wsl.exe`, `powershell.exe`, `/bin/bash`)",
    },
    // `ghoztty://` links.
    .{
        .mac = "rather than routed back through macOS, so it always",
        .win = "rather than routed back through Windows, so it always",
    },
    .{
        .mac = "A banner link ignores the usual Cmd / Cmd-Shift modifiers",
        .win = "A banner link ignores the usual Ctrl / Ctrl+Shift modifiers",
    },
    .{
        .mac = "schemes so LaunchServices never has to choose between them.",
        .win = "schemes so Windows never has to choose between them.",
    },
    // Key behaviors.
    .{
        .mac = "`+new-window` launches Ghoztty.app if no instance is running.",
        .win = "`+new-window` launches Ghoztty if no instance is running.",
    },
    // Examples.
    .{ .mac = "--split-command=\"exec zsh -l\"", .win = "--split-command=pwsh" },
    .{ .mac = "--command=zsh", .win = "--command=pwsh" },
    .{
        .mac = "- **Don't manually wrap with `zsh -lic`**",
        .win = "- **Don't manually wrap with `cmd /K` or `pwsh -NoExit -Command`**",
    },
};

/// Phrases that describe a Mac and never a Windows PC. The Windows install
/// must carry none of them (the T1327 validation criteria).
pub const mac_only_phrases = [_][]const u8{
    "Cmd-",    "Cmd+",         "Cmd /",          "trackpad",
    "two-finger", "zsh",       "Ghoztty.app",    "LaunchServices",
};

/// `text` with every `windows_rewrites` row applied (all occurrences).
/// Caller owns the result.
pub fn applyWindows(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out = try alloc.dupe(u8, text);
    errdefer alloc.free(out);
    for (windows_rewrites) |row| {
        if (std.mem.indexOf(u8, out, row.mac) == null) continue;
        const next = try std.mem.replaceOwned(u8, alloc, out, row.mac, row.win);
        alloc.free(out);
        out = next;
    }
    return out;
}

const testing = std.testing;
/// Every file of the shared skill (since main 71da9a680 a core plus reference
/// files); each is rewritten on its own as it installs.
const shared_files = @import("GhosttyAssets.zig").skillFiles("ghoztty") catch unreachable;

fn inSharedSkill(phrase: []const u8) bool {
    for (shared_files) |file| {
        if (std.mem.indexOf(u8, file.contents, phrase) != null) return true;
    }
    return false;
}

test "every Windows rewrite still matches the shared skill" {
    // Red here means a re-vendor reworded a paragraph this table rewrites:
    // update the row's `mac` phrase (and check its `win` sentence is still
    // the true one), or the Windows install ships main's Mac wording again.
    for (windows_rewrites) |row| {
        if (!inSharedSkill(row.mac)) {
            std.debug.print("stale rewrite row, phrase not found: {s}\n", .{row.mac});
            return error.StaleRewrite;
        }
    }
}

test "no Mac wording survives into the Windows skill" {
    for (shared_files) |file| {
        const win = try applyWindows(testing.allocator, file.contents);
        defer testing.allocator.free(win);
        for (mac_only_phrases) |phrase| {
            if (std.mem.indexOf(u8, win, phrase)) |at| {
                const lo = at -| 60;
                const hi = @min(win.len, at + phrase.len + 60);
                std.debug.print("Mac wording '{s}' survives in {s}: ...{s}...\n", .{ phrase, file.path, win[lo..hi] });
                return error.MacWording;
            }
        }
    }
    // The control: the shared document DOES carry them, so the loop above is
    // not passing over an empty or already-Windows text.
    for (mac_only_phrases) |phrase| {
        try testing.expect(inSharedSkill(phrase));
    }
}

test "the Windows wording names the Windows inputs" {
    var all: std.ArrayListUnmanaged(u8) = .empty;
    defer all.deinit(testing.allocator);
    for (shared_files) |file| {
        const win = try applyWindows(testing.allocator, file.contents);
        defer testing.allocator.free(win);
        // Everything else is untouched: the rewrite is phrase-level, so each
        // file's length stays the same order.
        try testing.expect(win.len + 2000 > file.contents.len and win.len < file.contents.len + 2000);
        try all.appendSlice(testing.allocator, win);
    }
    for ([_][]const u8{ "Ctrl+wheel", "Ctrl+R re-runs it", "Ctrl+Shift+B", "Ctrl+Shift+N", "Ctrl / Ctrl+Shift", "`cmd.exe`", "--command=pwsh" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, all.items, needle) != null);
    }
    // The core keeps its frontmatter.
    const core = try applyWindows(testing.allocator, shared_files[0].contents);
    defer testing.allocator.free(core);
    try testing.expect(std.mem.startsWith(u8, core, "---\n"));
}

test "a phrase that no longer occurs is a no-op, not a failure" {
    const out = try applyWindows(testing.allocator, "nothing Mac here\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("nothing Mac here\n", out);
}
