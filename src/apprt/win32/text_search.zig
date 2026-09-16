//! Text search shared by every win32 filter box (T288): the one
//! case-insensitive substring test behind the machine chooser's filter
//! (`MachineChooser.filterRows`, T172) and the Activity Monitor's process
//! filter (`activity_rows.matches`, T285).
//!
//! Both of those grew a private copy of the same scan, which is two copies of
//! the chance to be wrong and no way to notice (the T257 lesson). More to the
//! point, the fold's ALPHABET is a product decision — see below — and a
//! decision that lives in two files is a decision nobody can revisit.
//!
//! ## The fold is Unicode, the way macOS's is (T790, decision D71)
//!
//! macOS folds the same two filters with `localizedCaseInsensitiveContains`
//! (`MachineChooserView.swift:244-245,253`, `RemoteActivityMonitorView.swift:808`),
//! which is Unicode- and locale-aware. This module folded `A`-`Z` only until
//! T790, so typing `Ü` at a row reading `Zürich`, or any Cyrillic or Greek
//! letter in the other case, emptied the list where the Mac showed the hit.
//!
//! D71 settled the mechanism: use **Windows' own linguistic search**,
//! `FindNLSStringEx` with `LINGUISTIC_IGNORECASE`, rather than vendoring a
//! case-fold table that would then have to be kept current. The fold is
//! therefore whatever Windows says casing is for the user's locale — the
//! closest thing this platform has to what `localizedCaseInsensitiveContains`
//! means on the other one.
//!
//! ## Pure ASCII still takes the pure-ASCII path, on purpose
//!
//! When BOTH sides are ASCII the answer comes from `std.ascii.indexOfIgnoreCase`
//! and no OS call happens. Two reasons, and neither is only speed:
//!
//! 1. The Activity Monitor re-filters a ~500-row process table on every
//!    keystroke, and essentially every process name and machine name on this
//!    box is ASCII. Converting both sides to UTF-16 and crossing into
//!    `kernel32` 500 times per character typed buys nothing for those rows.
//! 2. It pins the answer for ASCII. A linguistic fold is locale-dependent, and
//!    under a Turkish locale `I` and `i` are deliberately NOT the same letter —
//!    so `ghoztty` would stop matching `GHOZTTY` for that user. Folding ASCII
//!    with ASCII rules and everything else linguistically keeps the common case
//!    stable and still answers the question T790 was filed about.
//!
//! The linguistic path is taken whenever either side carries a byte ≥ 0x80,
//! and it degrades to the ASCII scan — never to "no match" — if the text does
//! not fit the conversion buffers or the OS refuses the call. Off Windows (this
//! file compiles in every lane on BOTH seats) the fold is the ASCII one, which
//! is what the Mac seat's own filter boxes do not use anyway.
//!
//! The only OS import is the one `FindNLSStringEx` needs, behind a
//! `builtin.os.tag` comptime branch, so this module's tests still run in every
//! app-runtime lane — same deal as `chooser_rows.zig` and `activity_rows.zig`,
//! whose HWND-owning siblings cannot be reached from the `none` lane at all.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// UTF-16 units the linguistic path converts a haystack into. The haystacks
/// are process names, machine names and hostnames, so this is orders of
/// magnitude over what any of them run to; something past it falls back to the
/// ASCII scan rather than being silently truncated into a wrong answer.
const max_haystack_units = 2048;

/// UTF-16 units the linguistic path converts a needle into. The filter boxes
/// truncate what they read out of the EDIT well below this (`utf16_text`).
const max_needle_units = 512;

/// True when `needle` appears anywhere in `haystack`, folding case.
///
/// An empty needle matches everything (a filter box nobody has typed into
/// hides nothing), and an empty haystack is matched only by an empty needle.
/// ASCII-only pairs fold `A`-`Z`; anything else folds by Windows' linguistic
/// rules for the user's locale, which is what macOS's
/// `localizedCaseInsensitiveContains` does on that side (T790/D71).
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len == 0) return false;
    if (isAscii(haystack) and isAscii(needle))
        return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    return containsLinguistic(haystack, needle);
}

/// Whether every byte is ASCII, i.e. whether `std.ascii`'s fold is the whole
/// truth about this string's casing.
fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}

/// The ASCII fold, as the answer of last resort for a linguistic path that
/// could not run. It narrows a list rather than widening it, which is the safe
/// direction: a miss shows fewer rows, it never shows a wrong one.
fn asciiFallback(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn containsLinguistic(haystack: []const u8, needle: []const u8) bool {
    if (builtin.os.tag != .windows) return asciiFallback(haystack, needle);

    // UTF-8 never needs more UTF-16 units than it has bytes (1-3 byte
    // sequences are one unit, a 4-byte sequence is two), so a byte length that
    // fits the buffer guarantees the conversion does.
    if (haystack.len > max_haystack_units) return asciiFallback(haystack, needle);
    if (needle.len > max_needle_units) return asciiFallback(haystack, needle);

    var hay_buf: [max_haystack_units]u16 = undefined;
    var needle_buf: [max_needle_units]u16 = undefined;
    const hay_len = std.unicode.utf8ToUtf16Le(&hay_buf, haystack) catch
        return asciiFallback(haystack, needle);
    const needle_len = std.unicode.utf8ToUtf16Le(&needle_buf, needle) catch
        return asciiFallback(haystack, needle);
    if (hay_len == 0 or needle_len == 0) return asciiFallback(haystack, needle);

    // `FindNLSStringEx` answers "not found" and "I could not answer" with the
    // same -1, and only sets the last error in the second case — so clear it
    // first and read it back, instead of reporting an API failure as a row
    // that does not match.
    windows.kernel32.SetLastError(.SUCCESS);
    const found = nls.FindNLSStringEx(
        null, // LOCALE_NAME_USER_DEFAULT: the user's own casing rules
        nls.FIND_FROMSTART | nls.LINGUISTIC_IGNORECASE,
        &hay_buf,
        @intCast(hay_len),
        &needle_buf,
        @intCast(needle_len),
        null,
        null,
        null,
        0,
    );
    if (found >= 0) return true;
    if (windows.GetLastError() != .SUCCESS) return asciiFallback(haystack, needle);
    return false;
}

const windows = if (builtin.os.tag == .windows) std.os.windows else struct {};

/// The NLS entry point and its two flags, behind a comptime branch so nothing
/// Windows-shaped — `callconv(.winapi)` included — is ever analyzed on the Mac
/// seat, which compiles this file too.
const nls = if (builtin.os.tag == .windows) struct {
    /// Search forward from the start of the source string.
    pub const FIND_FROMSTART: u32 = 0x0040_0000;
    /// Ignore case linguistically — the whole point of this path.
    /// (`NORM_IGNORECASE` is the non-linguistic sibling and is NOT what
    /// macOS's filter does.)
    pub const LINGUISTIC_IGNORECASE: u32 = 0x0000_0010;

    /// Declared here rather than taken from `std.os.windows.kernel32`, which
    /// does not carry the NLS entry points as of Zig 0.15.2. Returns the
    /// 0-based index of the match, or -1 for "no match" AND for failure (see
    /// the last-error dance at the call site).
    pub extern "kernel32" fn FindNLSStringEx(
        lpLocaleName: ?[*:0]const u16,
        dwFindNLSStringFlags: u32,
        lpStringSource: [*]const u16,
        cchSource: i32,
        lpStringValue: [*]const u16,
        cchValue: i32,
        pcchFound: ?*i32,
        lpVersionInformation: ?*anyopaque,
        lpReserved: ?*anyopaque,
        sortHandle: isize,
    ) callconv(.winapi) i32;
} else struct {};

test "containsIgnoreCase: basic matches" {
    try testing.expect(containsIgnoreCase("Winbox", "box"));
    try testing.expect(containsIgnoreCase("Winbox", ""));
    try testing.expect(!containsIgnoreCase("Winbox", "mac"));
    try testing.expect(!containsIgnoreCase("ab", "abc")); // needle longer
}

test "containsIgnoreCase: needle longer than haystack is not a match" {
    try testing.expect(!containsIgnoreCase("ab", "abc"));
    try testing.expect(containsIgnoreCase("abc", "abc"));
    try testing.expect(containsIgnoreCase("abc", ""));
}

test "containsIgnoreCase: the fold runs in both directions, anywhere in the string" {
    try testing.expect(containsIgnoreCase("ghoztty-agent.exe", "AGENT"));
    try testing.expect(containsIgnoreCase("GHOZTTY-AGENT.EXE", "agent"));
    // Head and tail, not just the middle.
    try testing.expect(containsIgnoreCase("Winbox", "WIN"));
    try testing.expect(containsIgnoreCase("Winbox", "BOX"));
    // An empty haystack is only matched by an empty needle.
    try testing.expect(containsIgnoreCase("", ""));
    try testing.expect(!containsIgnoreCase("", "a"));
}

test "containsIgnoreCase: past 51 bytes std switches algorithms; both agree" {
    // `std.ascii.indexOfIgnoreCasePos` runs a linear scan under 52 haystack
    // bytes or a needle of 4 or fewer, and Boyer-Moore-Horspool otherwise. A
    // process table's `cmd` column is routinely longer than that, so the long
    // path is the one a user actually filters against.
    const long = "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\ghoztty-agent.exe";
    try testing.expect(long.len > 52);
    try testing.expect(containsIgnoreCase(long, "PROGRAMS"));
    try testing.expect(containsIgnoreCase(long, "ghoztty-AGENT.exe"));
    try testing.expect(!containsIgnoreCase(long, "ghoztty-agent.dll"));
    // The last byte of the haystack is reachable by the skip table too.
    try testing.expect(containsIgnoreCase(long, "E"));
}

test "containsIgnoreCase: an ASCII pair folds by ASCII rules, locale or no locale" {
    // The fast path's second job (see the module header): `I`/`i` stay the
    // same letter even where the user's locale says otherwise, so an
    // English-named process never stops matching its own name.
    try testing.expect(containsIgnoreCase("IPC", "ipc"));
    try testing.expect(containsIgnoreCase("ipc", "IPC"));
    try testing.expect(containsIgnoreCase("Ghoztty-IPC-Server", "ipc-SERVER"));
}

test "containsIgnoreCase: accented letters fold in both cases (T790)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // The exact pairs `text_search.zig` used to document as NOT matching.
    try testing.expect(containsIgnoreCase("Zürich", "ü"));
    try testing.expect(containsIgnoreCase("Zürich", "Ü"));
    try testing.expect(containsIgnoreCase("ZÜRICH", "ü"));
    try testing.expect(containsIgnoreCase("Zürich", "ZÜR"));
    try testing.expect(containsIgnoreCase("München", "MÜNCHEN"));
    // ASCII either side of a multi-byte sequence still folds.
    try testing.expect(containsIgnoreCase("Zürich", "z"));
    try testing.expect(containsIgnoreCase("Zürich", "RICH"));
    // And a genuine non-match is still a non-match.
    try testing.expect(!containsIgnoreCase("Zürich", "Öl"));
}

test "containsIgnoreCase: Cyrillic and Greek fold too (T790)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // Cyrillic: "Москва" / "москва".
    try testing.expect(containsIgnoreCase("Москва", "МОСКВА"));
    try testing.expect(containsIgnoreCase("МОСКВА", "москва"));
    try testing.expect(containsIgnoreCase("сервер-Москва", "МОСК"));
    try testing.expect(!containsIgnoreCase("Москва", "Киев"));
    // Greek.
    try testing.expect(containsIgnoreCase("Αθήνα", "ΑΘΉΝΑ"));
    try testing.expect(containsIgnoreCase("ΑΘΗΝΑ", "αθηνα"));
    try testing.expect(!containsIgnoreCase("Αθήνα", "Πάτρα"));
}

test "containsIgnoreCase: a non-ASCII needle against an ASCII row still misses" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // The linguistic path must not become a widener: typing an umlaut at a
    // table of ASCII process names empties it, exactly as on the Mac.
    try testing.expect(!containsIgnoreCase("ghoztty-agent.exe", "ü"));
    try testing.expect(!containsIgnoreCase("Winbox", "Ä"));
}

test "containsIgnoreCase: over-long input degrades to the ASCII fold, never to a crash" {
    // Past the conversion buffers the answer comes from `std.ascii`. It must
    // still be an ANSWER — the bound is why the filter box cannot be turned
    // into an overrun by a pasted path (the T989 lesson, applied ahead of time).
    var big: [max_haystack_units + 64]u8 = undefined;
    @memset(&big, 'a');
    // Put a multi-byte sequence in it so the ASCII fast path is not taken.
    big[0] = 0xC3;
    big[1] = 0xBC; // 'ü'
    big[big.len - 1] = 'Z';
    try testing.expect(containsIgnoreCase(&big, "z"));
    try testing.expect(!containsIgnoreCase(&big, "qqq"));

    var long_needle: [max_needle_units + 8]u8 = undefined;
    @memset(&long_needle, 'a');
    long_needle[0] = 0xC3;
    long_needle[1] = 0xBC;
    try testing.expect(!containsIgnoreCase("Winbox", &long_needle));
}
