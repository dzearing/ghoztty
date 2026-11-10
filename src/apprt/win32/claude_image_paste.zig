//! Ctrl+V with a picture AND a web address on the clipboard attaches the
//! picture in a Claude Code pane (T2721).
//!
//! T2694 made Ctrl+V attach a clipboard image in Claude Code on Windows: the
//! Claude integration binds Chat `ctrl+v` to `chat:imagePaste`, and Ghoztty
//! passes ^V through to the program whenever the clipboard holds no text
//! (T154). A browser's "Copy image" breaks that: beside the picture it can
//! publish the image's ADDRESS as plain text, so Ghoztty's own paste finds
//! text, pastes the URL, and Claude never sees the key.
//!
//! The rule here hands ^V to Claude for that one shape and nothing else:
//!
//! - **the clipboard holds an image**, and
//! - **its text is only an image's companion** - empty, or one line that is a
//!   `http(s):`, `data:image/`, `blob:` or `file:` address. That is what a
//!   browser writes beside a copied image. It is NOT what Excel, Word or a
//!   web-page selection writes: those publish a rendered picture too, but
//!   their text is the content the user copied (tab-separated cells, prose),
//!   and pasting a picture of a spreadsheet when the user wanted its cells
//!   would be a worse bug than the one being fixed. So real text always wins.
//! - **Claude Code is running in the pane** - a `claude.exe` under the pane's
//!   shell. Every other program owns its own ^V (the T2694 constraint), so a
//!   shell prompt or an editor with the same clipboard still gets the text.
//! - **Claude's Chat Ctrl+V is bound to `chat:imagePaste`** in the user's
//!   `~/.claude/keybindings.json`. Without that binding a passed-through ^V
//!   does nothing at all in Claude on Windows, and the user would lose the
//!   paste they have today.
//!
//! Mac never meets this: Cmd+V is the terminal's paste and Ctrl+V always
//! reaches Claude, so the user picks text or image by the key they press.
//!
//! Pure: no OS imports, so the tests run in every app-runtime lane.
const std = @import("std");

/// What `Surface.clipboardRequest` knows at the moment a paste is asked for.
pub const Facts = struct {
    /// The request is the user's paste keybind, not an OSC 52 read: a program
    /// asking to READ the clipboard is answered with its text, always.
    user_paste: bool,
    /// The clipboard holds a picture (`clipboard_image.available`).
    image: bool,
    /// The clipboard's text is only an image's companion
    /// (`textIsImageCompanion`).
    companion_text: bool,
    /// `claude.exe` runs under this pane's shell.
    claude_running: bool,
    /// Chat Ctrl+V is bound to image paste in Claude's keybindings.
    image_paste_bound: bool,
};

/// True when Ghoztty should NOT paste, and ^V goes to the program instead.
pub fn passToClaude(f: Facts) bool {
    return f.user_paste and f.image and f.companion_text and
        f.claude_running and f.image_paste_bound;
}

/// Whether `text` is what a browser writes beside a copied image rather than
/// content the user meant to paste: empty after trimming, or a single
/// whitespace-free token that is an image address.
pub fn textIsImageCompanion(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return true;
    // One token: a URL has no whitespace, and a cell grid, a sentence or a
    // second line all do.
    if (std.mem.indexOfAny(u8, t, " \t\r\n") != null) return false;
    const prefixes = [_][]const u8{ "https://", "http://", "data:image/", "blob:", "file:" };
    for (prefixes) |p| {
        if (t.len > p.len and std.ascii.startsWithIgnoreCase(t, p)) return true;
    }
    return false;
}

/// The executable Claude Code's native Windows installer puts on PATH. A
/// global npm install runs under `node.exe` instead, which cannot be told
/// apart from any other node program without reading its command line, so
/// that install keeps today's behaviour (the text pastes).
pub const claude_exe = "claude.exe";

/// Whether a Toolhelp32 `szExeFile` (UTF-16, NUL-padded) names Claude Code.
pub fn isClaudeExe(exe: []const u16) bool {
    const len = std.mem.indexOfScalar(u16, exe, 0) orelse exe.len;
    if (len != claude_exe.len) return false;
    for (exe[0..len], claude_exe) |w, c| {
        if (w > 0x7f) return false;
        if (std.ascii.toLower(@intCast(w)) != c) return false;
    }
    return true;
}

/// One row of a process snapshot.
pub const Proc = struct {
    pid: u32,
    ppid: u32,
    claude: bool,
};

/// Whether a Claude process descends from `root` (the pane's shell; `root`
/// itself counts, for a pane launched straight into `claude`). The parent
/// walk is depth-capped because Windows recycles pids, so a stale parent link
/// in a snapshot can form a cycle.
pub fn claudeUnder(procs: []const Proc, root: u32) bool {
    if (root == 0) return false;
    for (procs) |p| {
        if (!p.claude) continue;
        var cur = p.pid;
        var depth: usize = 0;
        while (depth < 128) : (depth += 1) {
            if (cur == root) return true;
            const parent = parentOf(procs, cur) orelse break;
            if (parent == cur or parent == 0) break;
            cur = parent;
        }
    }
    return false;
}

fn parentOf(procs: []const Proc, pid: u32) ?u32 {
    for (procs) |p| if (p.pid == pid) return p.ppid;
    return null;
}

// -----------------------------------------------------------------------------

const testing = std.testing;

test "a browser's image address is a companion; real content is not (T2721)" {
    // What a browser writes beside a copied image.
    try testing.expect(textIsImageCompanion(""));
    try testing.expect(textIsImageCompanion("  \r\n"));
    try testing.expect(textIsImageCompanion("https://example.com/cat.png"));
    try testing.expect(textIsImageCompanion("HTTP://example.com/a.jpg?x=1&y=2\r\n"));
    try testing.expect(textIsImageCompanion("data:image/png;base64,iVBORw0KGgo="));
    try testing.expect(textIsImageCompanion("blob:https://example.com/0a1b"));
    try testing.expect(textIsImageCompanion("file:///C:/Users/me/cat.png"));

    // What Excel, Word or a page selection writes beside THEIR picture.
    try testing.expect(!textIsImageCompanion("a\tb\tc\r\n1\t2\t3\r\n"));
    try testing.expect(!textIsImageCompanion("Quarterly revenue grew 12%"));
    try testing.expect(!textIsImageCompanion("https://a.example/x.png\nhttps://b.example/y.png"));
    try testing.expect(!textIsImageCompanion("see https://example.com/cat.png"));
    // A single word is content, not an address.
    try testing.expect(!textIsImageCompanion("hello"));
    // A bare scheme with nothing after it is not an address either.
    try testing.expect(!textIsImageCompanion("https://"));
    // Not an image data URL.
    try testing.expect(!textIsImageCompanion("data:text/plain,hi"));
}

test "every fact has to hold before ^V is handed to Claude (T2721)" {
    const all: Facts = .{
        .user_paste = true,
        .image = true,
        .companion_text = true,
        .claude_running = true,
        .image_paste_bound = true,
    };
    try testing.expect(passToClaude(all));

    inline for (std.meta.fields(Facts)) |field| {
        var f = all;
        @field(f, field.name) = false;
        try testing.expect(!passToClaude(f));
    }
}

test "isClaudeExe matches claude.exe in any case, and nothing else (T2721)" {
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    try testing.expect(isClaudeExe(W("claude.exe")));
    try testing.expect(isClaudeExe(W("Claude.EXE")));
    var padded = [_]u16{0} ** 260;
    @memcpy(padded[0..10], W("claude.exe"));
    try testing.expect(isClaudeExe(&padded));

    try testing.expect(!isClaudeExe(W("node.exe")));
    try testing.expect(!isClaudeExe(W("claude")));
    try testing.expect(!isClaudeExe(W("claude.exe.bak")));
    try testing.expect(!isClaudeExe(W("xclaude.exe")));
    try testing.expect(!isClaudeExe(W("")));
}

test "claudeUnder finds Claude anywhere below the pane's shell (T2721)" {
    // app 100 -> shell 200 -> claude 300 -> bash hook 400; another pane's
    // shell 201 has nothing.
    const procs = [_]Proc{
        .{ .pid = 100, .ppid = 0, .claude = false },
        .{ .pid = 200, .ppid = 100, .claude = false },
        .{ .pid = 201, .ppid = 100, .claude = false },
        .{ .pid = 300, .ppid = 200, .claude = true },
        .{ .pid = 400, .ppid = 300, .claude = false },
    };
    try testing.expect(claudeUnder(&procs, 200));
    try testing.expect(!claudeUnder(&procs, 201));
    // The shell itself may be claude (a pane launched with `-e claude`).
    try testing.expect(claudeUnder(&procs, 300));
    // No shell pid (a remote pane, or not up yet): never.
    try testing.expect(!claudeUnder(&procs, 0));
    // Claude below a cmd /c wrapper still counts.
    const wrapped = [_]Proc{
        .{ .pid = 200, .ppid = 1, .claude = false },
        .{ .pid = 250, .ppid = 200, .claude = false },
        .{ .pid = 300, .ppid = 250, .claude = true },
    };
    try testing.expect(claudeUnder(&wrapped, 200));
}

test "claudeUnder terminates on a recycled-pid cycle (T2721)" {
    const procs = [_]Proc{
        .{ .pid = 10, .ppid = 20, .claude = true },
        .{ .pid = 20, .ppid = 10, .claude = false },
        .{ .pid = 4, .ppid = 4, .claude = true },
    };
    try testing.expect(!claudeUnder(&procs, 99));
    try testing.expect(claudeUnder(&procs, 20));
}
