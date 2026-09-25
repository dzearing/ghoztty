//! Pure tab-tooltip text derivation (T447) — the "what does hovering a tab
//! say" half of the tab tooltip, kept OS-free so the none lane can assert it
//! (the `tab_strip_layout.zig` pattern). The control plumbing lives in
//! `Window.zig`; nothing here touches an HWND.
//!
//! The tooltip surfaces the hovered tab's focused pane's working directory
//! (or a viewer pane's current location), so several tabs on several
//! checkouts can be told apart without running a command — the
//! Windows-native translation of the Mac titlebar proxy icon (translate the
//! feature, not the implementation). Two transforms, matching how a person
//! reads a path:
//!
//! - the home-directory prefix reads as `~` (Mac's `abbreviatedPath`), and
//! - a path longer than `max_len` drops MIDDLE components, never the tail:
//!   the deepest directories are what distinguish two checkouts of the same
//!   repo, so they are the part that must survive.

const std = @import("std");

/// Max UTF-8 bytes of tooltip text before middle components are elided.
/// Long enough for any realistic repo path, short enough that the tooltip
/// never spans half a monitor.
pub const max_len: usize = 96;

/// Max UTF-8 bytes of the whole (possibly two-line) tooltip: a clamped
/// title line, the newline, and an elided location line (T556).
pub const max_tip_len: usize = max_len * 2 + 1;

/// The elision mark. One character, three UTF-8 bytes.
const ellipsis = "…";

/// True when `c` separates path components. Both separators are accepted
/// everywhere: OSC 7 emits `/` from git-bash and `\` from PowerShell, and a
/// viewer location can be either.
inline fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

/// ASCII case-insensitive equality — Windows paths compare caseless, and
/// drive letters arrive in either case (`c:\` from MSYS, `C:\` from
/// PowerShell). Multibyte sequences compare byte-exact, which is the
/// conservative direction: a miss keeps the full path, never corrupts it.
fn eqlNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Replace the home-directory prefix of `path` with `~` into `out`.
/// Only a whole-component prefix matches: `C:\Users\Dav` does not abbreviate
/// `C:\Users\David`. Trailing separators on `home` are ignored. A null or
/// empty home, or no match, copies `path` verbatim.
///
/// `out.len >= path.len` is the caller's contract (the transform only ever
/// shrinks); a too-small buffer returns the unabbreviated tail-truncated
/// copy rather than tripping an assert in release.
pub fn tildeHome(out: []u8, path: []const u8, home: ?[]const u8) []const u8 {
    const n = @min(path.len, out.len);
    const h_raw = home orelse {
        @memcpy(out[0..n], path[0..n]);
        return out[0..n];
    };
    // Strip trailing separators from home so `C:\Users\David\` still
    // matches `C:\Users\David\git`.
    var h = h_raw;
    while (h.len > 0 and isSep(h[h.len - 1])) h = h[0 .. h.len - 1];
    if (h.len == 0 or path.len < h.len or !eqlNoCase(path[0..h.len], h) or
        (path.len > h.len and !isSep(path[h.len])))
    {
        @memcpy(out[0..n], path[0..n]);
        return out[0..n];
    }
    const rest = path[h.len..];
    const rest_n = @min(rest.len, out.len -| 1);
    out[0] = '~';
    @memcpy(out[1 .. 1 + rest_n], rest[0..rest_n]);
    return out[0 .. 1 + rest_n];
}

/// The largest index `>= from` in `s` that starts a UTF-8 codepoint, so a
/// cut never leaves a dangling continuation byte at the front of the kept
/// tail.
fn utf8CeilBoundary(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] & 0xC0) == 0x80) i += 1;
    return i;
}

/// Keep the LAST bytes of `path` that fit `max` (minus the ellipsis), cut on
/// a UTF-8 boundary — the fallback when component elision cannot help (no
/// separators, or even the final component alone is over budget). The tail
/// survives because it is the distinguishing part.
fn tailTruncate(out: []u8, path: []const u8, max: usize) []const u8 {
    const budget = max -| ellipsis.len;
    const start = utf8CeilBoundary(path, path.len -| budget);
    const tail = path[start..];
    @memcpy(out[0..ellipsis.len], ellipsis);
    @memcpy(out[ellipsis.len .. ellipsis.len + tail.len], tail);
    return out[0 .. ellipsis.len + tail.len];
}

/// Elide middle path components so the result fits `max` bytes: the root
/// component and as many TRAILING components as fit are kept, joined with
/// `…` — `~\git\ghoztty\src\apprt\win32` over budget becomes
/// `~\…\src\apprt\win32`, never a cut that loses the leaf. A path already
/// within budget is copied verbatim. `out.len >= max` is the caller's
/// contract.
pub fn elide(out: []u8, path: []const u8, max: usize) []const u8 {
    if (path.len <= max) {
        @memcpy(out[0..path.len], path);
        return out[0..path.len];
    }
    if (max <= ellipsis.len) return tailTruncate(out, path, max);

    // The separator style of the joined result is the path's own.
    var sep: u8 = '\\';
    for (path) |c| {
        if (isSep(c)) {
            sep = c;
            break;
        }
    }

    // Root component (drive letter, `~`, or a URL scheme's head) plus the
    // fixed elision infix: `root` + sep + `…` + sep.
    const root_end = for (path, 0..) |c, i| {
        if (isSep(c)) break i;
    } else path.len;
    const root = path[0..root_end];
    const overhead = root.len + 1 + ellipsis.len + 1;
    if (overhead >= max) return tailTruncate(out, path, max);
    const budget = max - overhead;

    // Grow the kept tail backwards a component at a time. `start` lands on
    // the byte AFTER a separator, so the kept tail is whole components.
    var start: usize = path.len;
    var i: usize = path.len;
    while (i > root_end + 1) {
        i -= 1;
        if (isSep(path[i])) {
            const cand = path[i + 1 ..];
            if (cand.len > budget) break;
            start = i + 1;
        }
    }
    if (start == path.len) return tailTruncate(out, path, max);
    const tail = path[start..];

    @memcpy(out[0..root.len], root);
    var at = root.len;
    out[at] = sep;
    at += 1;
    @memcpy(out[at .. at + ellipsis.len], ellipsis);
    at += ellipsis.len;
    out[at] = sep;
    at += 1;
    @memcpy(out[at .. at + tail.len], tail);
    return out[0 .. at + tail.len];
}

/// One-call composition for the control code: tilde-abbreviate, then elide
/// to `max_len`. Null for an empty location — an empty tooltip must not
/// show, the way an empty pane reads as an answer, not an error (T181).
/// `out.len >= max_len` is the caller's contract.
pub fn tipText(out: []u8, location_raw: []const u8, home: ?[]const u8) ?[]const u8 {
    if (location_raw.len == 0) return null;
    const location = trimLocationSep(location_raw);
    var scratch: [1024]u8 = undefined;
    const abbrev = if (location.len <= scratch.len)
        tildeHome(&scratch, location, home)
    else
        location;
    return elide(out, abbrev, max_len);
}

/// Clamp a TITLE to `max` bytes keeping the HEAD, cut on a UTF-8 boundary,
/// with a trailing ellipsis. The head survives because that is what the
/// strip's own `DT_END_ELLIPSIS` paint keeps — a tooltip line that elided a
/// different end than the tab it explains would read as a second title.
fn clampTitle(out: []u8, title: []const u8, max: usize) []const u8 {
    if (title.len <= max) {
        @memcpy(out[0..title.len], title);
        return out[0..title.len];
    }
    var end = max -| ellipsis.len;
    while (end > 0 and (title[end] & 0xC0) == 0x80) end -= 1;
    @memcpy(out[0..end], title[0..end]);
    @memcpy(out[end .. end + ellipsis.len], ellipsis);
    return out[0 .. end + ellipsis.len];
}

/// Drop trailing path separators — `~\git\x\` and `~\git\x` are the same
/// place, and the two halves of the tip do not agree about the trailing one:
/// the live cwd read off the OS can carry it where the shell-reported title
/// does not.
fn trimTrailingSeps(s: []const u8) []const u8 {
    var out = s;
    while (out.len > 0 and isSep(out[out.len - 1])) out = out[0 .. out.len - 1];
    return out;
}

/// The location line's spelling of a trailing separator (T1623): the live cwd
/// read off the OS can end in one where the OSC-7 cache and a viewer location
/// do not, so the same place read `~\x\` one hover and `~\x` the next. Trimmed
/// only when a component precedes it — on a root the separator IS the path
/// (`C:\` is not `C:`, `/` is not empty) — and never on a URL, where a
/// trailing slash can name a different resource.
fn trimLocationSep(s: []const u8) []const u8 {
    if (std.mem.indexOf(u8, s, "://") != null) return s;
    const t = trimTrailingSeps(s);
    if (t.len == 0 or t[t.len - 1] == ':') return s;
    return t;
}

/// Path equality for the "does the title say anything new" question: caseless
/// (Windows), separator-style agnostic (a title may arrive from an MSYS shell
/// with `/` while the OS read answers `\`), trailing separator ignored.
fn eqlPath(a_raw: []const u8, b_raw: []const u8) bool {
    const a = trimTrailingSeps(a_raw);
    const b = trimTrailingSeps(b_raw);
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        // Either both bytes separate components, or they compare caseless.
        if (isSep(ca) or isSep(cb)) {
            if (!(isSep(ca) and isSep(cb))) return false;
            continue;
        }
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// True when the title would only repeat the location line (T1622). An
/// UNTITLED pane is titled from its pwd — upstream's rule, and the one T512
/// leans on so a strip of cmd.exe tabs does not read as a row of
/// `C:\WINDOWS\system32\cmd.exe` — so "the title IS the cwd" is the COMMON
/// shape here, not a corner case. Riding that title above the location gave a
/// two-line tooltip whose first line was the RAW path and whose second was the
/// same path with `~`: the redundant line T556 exists to avoid, in its most
/// frequent form. Compared after `~`-abbreviation, so a shell that titles
/// itself `~\git\x` matches the `C:\Users\…\git\x` the OS reports.
fn titleRepeatsLocation(title: []const u8, location: []const u8, home: ?[]const u8) bool {
    if (title.len == 0 or location.len == 0) return false;
    // Raw first: `tildeHome` matches the home prefix caselessly but NOT across
    // separator styles, so an MSYS-shaped `c:/users/david/x` title never
    // abbreviates while the OS-read location does — and the two abbreviations
    // then disagree about a place they both name. Comparing raw is exactly the
    // test that survives that.
    if (eqlPath(title, location)) return true;
    var tbuf: [1024]u8 = undefined;
    var lbuf: [1024]u8 = undefined;
    if (title.len > tbuf.len or location.len > lbuf.len) return false;
    // Then abbreviated, for a shell that titles itself `~\git\x` where the OS
    // answers the full `C:\Users\…\git\x`.
    return eqlPath(
        tildeHome(&tbuf, title, home),
        tildeHome(&lbuf, location, home),
    );
}

/// Title-aware composition (T556). When the strip ELIDED the painted title,
/// the full title rides as a first line above the location — the one thing a
/// hover could not previously rescue. When the title fit, the tip stays
/// location-only: a line repeating what the tab already shows is noise. An
/// elided title with no location shows title-only; neither is null, exactly
/// as `tipText`. `out.len >= max_tip_len` is the caller's contract.
pub fn tipTextTitled(
    out: []u8,
    title: []const u8,
    title_elided: bool,
    location: []const u8,
    home: ?[]const u8,
) ?[]const u8 {
    if (!title_elided or title.len == 0) return tipText(out, location, home);
    // A title that only restates the location is dropped, elided or not
    // (T1622) — the location line already says it, in the friendlier form.
    if (titleRepeatsLocation(title, location, home)) return tipText(out, location, home);

    var tbuf: [max_len]u8 = undefined;
    const t = clampTitle(&tbuf, title, max_len);

    var lbuf: [max_len]u8 = undefined;
    const loc = tipText(&lbuf, location, home) orelse {
        @memcpy(out[0..t.len], t);
        return out[0..t.len];
    };

    @memcpy(out[0..t.len], t);
    out[t.len] = '\n';
    @memcpy(out[t.len + 1 .. t.len + 1 + loc.len], loc);
    return out[0 .. t.len + 1 + loc.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tildeHome: replaces the home prefix with ~" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        tildeHome(&buf, "C:\\Users\\David\\git\\ghoztty", "C:\\Users\\David"),
    );
}

test "tildeHome: exact home is just ~" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "~",
        tildeHome(&buf, "C:\\Users\\David", "C:\\Users\\David"),
    );
}

test "tildeHome: case-insensitive and separator-style agnostic" {
    var buf: [256]u8 = undefined;
    // MSYS-style report of the same directory: lowercase drive, forward
    // slashes in the path half.
    try testing.expectEqualStrings(
        "~/git/x",
        tildeHome(&buf, "c:\\users\\david/git/x", "C:\\Users\\David"),
    );
}

test "tildeHome: trailing separator on home still matches" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git",
        tildeHome(&buf, "C:\\Users\\David\\git", "C:\\Users\\David\\"),
    );
}

test "tildeHome: a partial component never abbreviates" {
    var buf: [256]u8 = undefined;
    // `C:\Users\Dav` is a PREFIX of the string but not of the path.
    try testing.expectEqualStrings(
        "C:\\Users\\David2\\git",
        tildeHome(&buf, "C:\\Users\\David2\\git", "C:\\Users\\David"),
    );
}

test "tildeHome: null or empty home copies verbatim" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty",
        tildeHome(&buf, "D:\\git\\ghoztty", null),
    );
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty",
        tildeHome(&buf, "D:\\git\\ghoztty", ""),
    );
}

test "elide: a short path is untouched" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        elide(&buf, "~\\git\\ghoztty", max_len),
    );
}

test "elide: middle components go, root and leaf components stay" {
    var buf: [128]u8 = undefined;
    // 116 bytes: over budget by enough that the 80-byte component must go.
    const long = "~\\git\\" ++ ("A" ** 80) ++ "\\nested\\deeper\\src\\apprt\\win32";
    const got = elide(&buf, long, max_len);
    try testing.expect(got.len <= max_len);
    try testing.expectEqualStrings(
        "~\\" ++ ellipsis ++ "\\nested\\deeper\\src\\apprt\\win32",
        got,
    );
}

test "elide: keeps the path's own separator style" {
    var buf: [128]u8 = undefined;
    const long = "~/git/" ++ ("A" ** 80) ++ "/nested/deeper/src/apprt/win32";
    const got = elide(&buf, long, max_len);
    try testing.expect(std.mem.startsWith(u8, got, "~/" ++ ellipsis ++ "/"));
    try testing.expect(std.mem.endsWith(u8, got, "/src/apprt/win32"));
}

test "elide: the whole budget is used before eliding more" {
    var buf: [128]u8 = undefined;
    // Every trailing component fits: elision keeps them ALL, not just the
    // leaf — only the oversized middle component is dropped.
    const long = "C:\\" ++ ("x" ** 120) ++ "\\aa\\bb\\cc\\dd";
    const got = elide(&buf, long, max_len);
    try testing.expectEqualStrings("C:\\" ++ ellipsis ++ "\\aa\\bb\\cc\\dd", got);
}

test "elide: no separators falls back to a tail cut" {
    var buf: [128]u8 = undefined;
    const long = "z" ** 200;
    const got = elide(&buf, long, max_len);
    try testing.expect(got.len <= max_len);
    try testing.expect(std.mem.startsWith(u8, got, ellipsis));
    try testing.expect(std.mem.endsWith(u8, got, "zzz"));
}

test "elide: an oversized final component keeps its tail" {
    var buf: [128]u8 = undefined;
    const long = "C:\\a\\" ++ ("y" ** 150);
    const got = elide(&buf, long, max_len);
    try testing.expect(got.len <= max_len);
    try testing.expect(std.mem.startsWith(u8, got, ellipsis));
    try testing.expect(std.mem.endsWith(u8, got, "yyy"));
}

test "elide: a tail cut never splits a UTF-8 sequence" {
    var buf: [128]u8 = undefined;
    // 2-byte codepoints back to back: an arbitrary byte cut has ~50% odds
    // of landing mid-sequence, so a bad cut fails validity below.
    const long = "é" ** 120; // 240 bytes, no separators
    const got = elide(&buf, long, max_len);
    try testing.expect(got.len <= max_len);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
}

test "tipText: composes tilde + elision" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        tipText(&buf, "C:\\Users\\David\\git\\ghoztty", "C:\\Users\\David").?,
    );
}

test "tipText: empty location is null, not an empty tooltip" {
    var buf: [128]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), tipText(&buf, "", "C:\\Users\\David"));
}

test "tipText: a trailing separator is dropped after a component (T1623)" {
    var buf: [128]u8 = undefined;
    const home = "C:\\Users\\David";
    try testing.expectEqualStrings("~\\git\\x", tipText(&buf, "C:\\Users\\David\\git\\x\\", home).?);
    try testing.expectEqualStrings("~\\git\\x", tipText(&buf, "C:\\Users\\David\\git\\x", home).?);
    try testing.expectEqualStrings("~/git/x", tipText(&buf, "C:\\Users\\David/git/x//", home).?);
    try testing.expectEqualStrings("D:\\git", tipText(&buf, "D:\\git\\", home).?);
    try testing.expectEqualStrings("~", tipText(&buf, "C:\\Users\\David\\", home).?);
    try testing.expectEqualStrings("\\\\srv\\share", tipText(&buf, "\\\\srv\\share\\", home).?);
}

test "tipText: a root keeps its load-bearing separator (T1623)" {
    var buf: [128]u8 = undefined;
    const home = "C:\\Users\\David";
    try testing.expectEqualStrings("C:\\", tipText(&buf, "C:\\", home).?);
    try testing.expectEqualStrings("c:/", tipText(&buf, "c:/", home).?);
    try testing.expectEqualStrings("/", tipText(&buf, "/", home).?);
    try testing.expectEqualStrings("\\", tipText(&buf, "\\", null).?);
}

test "tipText: a viewer URL passes through untouched" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "http://localhost:3000/",
        tipText(&buf, "http://localhost:3000/", "C:\\Users\\David").?,
    );
}

test "tipTextTitled: an elided title rides above the location" {
    var buf: [max_tip_len]u8 = undefined;
    try testing.expectEqualStrings(
        "my very long tab title\n~\\git\\ghoztty",
        tipTextTitled(
            &buf,
            "my very long tab title",
            true,
            "C:\\Users\\David\\git\\ghoztty",
            "C:\\Users\\David",
        ).?,
    );
}

test "tipTextTitled: a title that fit keeps the tip location-only" {
    var buf: [max_tip_len]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        tipTextTitled(
            &buf,
            "short",
            false,
            "C:\\Users\\David\\git\\ghoztty",
            "C:\\Users\\David",
        ).?,
    );
}

test "tipTextTitled: a pwd-derived title does not repeat the location" {
    var buf: [max_tip_len]u8 = undefined;
    // The common shape (T1622): an untitled pane is titled from its pwd, so
    // the title IS the raw path the location line already carries. One line,
    // the friendly one — not the raw path above its own abbreviation.
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        tipTextTitled(
            &buf,
            "C:\\Users\\David\\git\\ghoztty",
            true,
            "C:\\Users\\David\\git\\ghoztty",
            "C:\\Users\\David",
        ).?,
    );
}

test "tipTextTitled: a repeat is seen through a trailing separator and case" {
    var buf: [max_tip_len]u8 = undefined;
    // The live cwd read off the OS carries a trailing separator the shell's
    // title does not, and an MSYS-reported title differs in case and slash
    // style — none of which makes it a different place. The location line
    // drops that trailing separator too (T1623); a root keeps its own.
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        tipTextTitled(
            &buf,
            "c:/users/david/git/ghoztty",
            true,
            "C:\\Users\\David\\git\\ghoztty\\",
            "C:\\Users\\David",
        ).?,
    );
}

test "tipTextTitled: a title ALREADY in ~ form still counts as a repeat" {
    var buf: [max_tip_len]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        tipTextTitled(
            &buf,
            "~\\git\\ghoztty",
            true,
            "C:\\Users\\David\\git\\ghoztty",
            "C:\\Users\\David",
        ).?,
    );
}

test "tipTextTitled: a title that is a DIFFERENT path still rides above" {
    var buf: [max_tip_len]u8 = undefined;
    // The suppression is "says nothing new", not "looks like a path": a tab
    // titled with another directory is information the location line lacks.
    try testing.expectEqualStrings(
        "C:\\Windows\\System32\n~\\git\\ghoztty",
        tipTextTitled(
            &buf,
            "C:\\Windows\\System32",
            true,
            "C:\\Users\\David\\git\\ghoztty",
            "C:\\Users\\David",
        ).?,
    );
}

test "tipTextTitled: a repeated title with no location is still title-only" {
    var buf: [max_tip_len]u8 = undefined;
    // An empty location cannot be repeated, so the elided title survives —
    // the T556 title-only path is not what T1622 narrowed.
    try testing.expectEqualStrings(
        "C:\\Users\\David\\git\\ghoztty",
        tipTextTitled(&buf, "C:\\Users\\David\\git\\ghoztty", true, "", "C:\\Users\\David").?,
    );
}

test "tipTextTitled: elided title with no location shows title-only" {
    var buf: [max_tip_len]u8 = undefined;
    try testing.expectEqualStrings(
        "orphan title",
        tipTextTitled(&buf, "orphan title", true, "", null).?,
    );
}

test "tipTextTitled: no title and no location is null" {
    var buf: [max_tip_len]u8 = undefined;
    try testing.expectEqual(
        @as(?[]const u8, null),
        tipTextTitled(&buf, "", true, "", null),
    );
}

test "tipTextTitled: an overlong title clamps at the head with ellipsis" {
    var buf: [max_tip_len]u8 = undefined;
    const long = "T" ++ ("x" ** 150);
    const got = tipTextTitled(&buf, long, true, "C:\\d", null).?;
    const nl = std.mem.indexOfScalar(u8, got, '\n').?;
    const title_line = got[0..nl];
    try testing.expect(title_line.len <= max_len);
    try testing.expect(std.mem.startsWith(u8, title_line, "Txxx"));
    try testing.expect(std.mem.endsWith(u8, title_line, "…"));
    try testing.expectEqualStrings("C:\\d", got[nl + 1 ..]);
}

test "tipTextTitled: the title clamp never splits a UTF-8 sequence" {
    var buf: [max_tip_len]u8 = undefined;
    const long = "é" ** 120; // 240 bytes
    const got = tipTextTitled(&buf, long, true, "", null).?;
    try testing.expect(got.len <= max_len);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
    try testing.expect(std.mem.endsWith(u8, got, "…"));
}
