//! A viewer page's light/dark on a glass sheet (T3720; win32
//! `viewer_glass.pageScheme`, T1885; Mac: the window's appearance follows the
//! terminal background, and the web view follows the window).
//!
//! On glass our own template pages are see-through (T3622), so their ink sits
//! over the sheet - the terminal background tinted over the desk - and their
//! light/dark has to be that background's. WebKitGTK only takes
//! `prefers-color-scheme` from the app's style (the libadwaita style manager,
//! which under `window-theme = auto` merely PREFERS the terminal's scheme, so a
//! dark desktop wins over a light terminal). It has no per-view setting (none
//! in WebKitGTK 2.52's headers), and the app style is the chrome's too, so the
//! scheme is held in the PAGE instead: `applyJs` rewrites the template's
//! `prefers-color-scheme` media conditions to the forced answer and sets the
//! root's `color-scheme` (form controls, scrollbars); `null` restores them.
//!
//! The template's style sheets come from our `ghoztty-viewer` scheme, which is
//! registered LOCAL, so page script cannot read their rules (`cssRules`
//! throws SecurityError, measured 2026-11-26). So the script re-points each
//! template `<link>` at `?gz-scheme=<light|dark>` and the scheme handler,
//! which serves those bytes anyway, rewrites the conditions in the CSS it
//! returns (`schemeFromQuery`, `rewriteCss`). A `<link media=...>` attribute
//! and an inline `<style>` the page CAN read are rewritten in place.
//!
//! Only template pages are held - they are the ones drawn on the sheet. A
//! website or a rendered `.html` file keeps its own background, and its
//! style sheets may not even be readable from the page (cross-origin), so it
//! keeps following the app style. Pure: no GTK, no WebKit.
const std = @import("std");
const glass = @import("../win32/viewer_glass.zig");
const color_math = @import("../win32/color_math.zig");
const content = @import("../win32/viewer_content.zig");

pub const Scheme = glass.Scheme;

/// The scheme a pane's page is held to, or null to follow the app style.
/// `bg` is the terminal background the sheet is tinted with.
pub fn forced(on_glass: bool, mode: content.Mode, bg: color_math.Rgb) ?Scheme {
    if (!mode.usesTemplate() or !glass.drawsOnGlass(on_glass, mode)) return null;
    // On glass `pageScheme` ignores the OS answer; pass either.
    return glass.pageScheme(Scheme, .light, true, bg);
}

/// The page script that holds (or releases) the scheme. Idempotent and
/// re-runnable: the first run remembers each media list's own text, so a
/// flip or a release always rewrites from the original. A MutationObserver on
/// the head re-applies it to a style sheet that arrives later.
pub fn applyJs(s: ?Scheme) []const u8 {
    return if (s) |v| switch (v) {
        .light => script("light"),
        .dark => script("dark"),
    } else script("");
}

/// The query parameter a held template style sheet is requested with.
pub const query_key = "gz-scheme";

/// The scheme a template style sheet request holds (`...css?gz-scheme=dark`),
/// or null for an ordinary request.
pub fn schemeFromQuery(uri: []const u8) ?Scheme {
    const q = std.mem.indexOfScalar(u8, uri, '?') orelse return null;
    var it = std.mem.splitScalar(u8, uri[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], query_key)) continue;
        const v = pair[eq + 1 ..];
        if (std.mem.eql(u8, v, "light")) return .light;
        if (std.mem.eql(u8, v, "dark")) return .dark;
        return null;
    }
    return null;
}

/// An always-true and an always-false media feature: what a held
/// `(prefers-color-scheme: X)` becomes. A negative width is an invalid query,
/// which a media list reads as `not all`.
const cond_true = "(min-width:0px)";
const cond_false = "(max-width:-1px)";

/// `css` with every `(prefers-color-scheme: light|dark)` condition replaced
/// by the answer `s` gives (whitespace and case as CSS allows). Caller owns
/// the result.
pub fn rewriteCss(alloc: std.mem.Allocator, css: []const u8, s: Scheme) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < css.len) {
        if (css[i] == '(') if (matchCondition(css[i..])) |m| {
            try out.appendSlice(alloc, if (m.scheme == s) cond_true else cond_false);
            i += m.len;
            continue;
        };
        try out.append(alloc, css[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

const Match = struct { scheme: Scheme, len: usize };

/// `( prefers-color-scheme : light|dark )` at the start of `t`.
fn matchCondition(t: []const u8) ?Match {
    var i: usize = 1;
    i = skipWs(t, i);
    const name = "prefers-color-scheme";
    if (t.len < i + name.len or !std.ascii.eqlIgnoreCase(t[i .. i + name.len], name)) return null;
    i = skipWs(t, i + name.len);
    if (i >= t.len or t[i] != ':') return null;
    i = skipWs(t, i + 1);
    var sch: Scheme = undefined;
    if (t.len >= i + 5 and std.ascii.eqlIgnoreCase(t[i .. i + 5], "light")) {
        sch = .light;
        i += 5;
    } else if (t.len >= i + 4 and std.ascii.eqlIgnoreCase(t[i .. i + 4], "dark")) {
        sch = .dark;
        i += 4;
    } else return null;
    i = skipWs(t, i);
    if (i >= t.len or t[i] != ')') return null;
    return .{ .scheme = sch, .len = i + 1 };
}

fn skipWs(t: []const u8, start: usize) usize {
    var i = start;
    while (i < t.len and std.ascii.isWhitespace(t[i])) i += 1;
    return i;
}

fn script(comptime s: []const u8) []const u8 {
    return "(function(s){var R=window.__gzScheme;if(!R){if(!s)return 'os';" ++
        "R=window.__gzScheme={m:new Map(),l:new Map(),s:''};" ++
        // Our template's <link>s: the media attribute in place, and the sheet
        // itself re-requested held (the scheme handler rewrites it).
        "R.link=function(l){var o=R.l.get(l);if(!o){o={h:l.getAttribute('href')||'',m:l.getAttribute('media')};R.l.set(l,o)}" ++
        "if(o.m&&/prefers-color-scheme/i.test(o.m)){var nm=R.q(o.m);if(l.getAttribute('media')!==nm)l.setAttribute('media',nm)}" ++
        "if(l.href.indexOf('ghoztty-viewer:')!==0||!/\\.css($|[?#])/i.test(o.h))return;" ++
        "var nh=R.s?o.h+(o.h.indexOf('?')<0?'?':'&')+'" ++ query_key ++ "='+R.s:o.h;if(l.getAttribute('href')!==nh)l.setAttribute('href',nh)};" ++
        "R.q=function(o){return R.s?o.replace(/\\(\\s*prefers-color-scheme\\s*:\\s*(light|dark)\\s*\\)/gi," ++
        "function(_,v){return v.toLowerCase()===R.s?'(min-width:0px)':'(max-width:-1px)'}):o};" ++
        "R.one=function(l){if(!l)return;var o=R.m.get(l);if(o===undefined){o=l.mediaText;" ++
        "if(!/prefers-color-scheme/i.test(o))return;R.m.set(l,o)}var n=R.q(o);if(l.mediaText!==n)l.mediaText=n};" ++
        "R.walk=function(rs){if(!rs)return;for(var i=0;i<rs.length;i++){var r=rs[i];if(r.media)R.one(r.media);" ++
        "if(r.cssRules)R.walk(r.cssRules)}};" ++
        "R.fix=function(){var ls=document.querySelectorAll('link[rel~=stylesheet]');for(var j=0;j<ls.length;j++)R.link(ls[j]);" ++
        "var ss=document.styleSheets;for(var i=0;i<ss.length;i++){var sh=ss[i];if(sh.ownerNode&&sh.ownerNode.tagName==='LINK')continue;R.one(sh.media);" ++
        "var rs=null;try{rs=sh.cssRules}catch(e){}R.walk(rs)}" ++
        "if(document.documentElement)document.documentElement.style.colorScheme=R.s||''};" ++
        "new MutationObserver(function(){R.fix()}).observe(document.head||document.documentElement,{childList:true,subtree:true});" ++
        "document.addEventListener('load',function(e){if(e.target&&e.target.tagName==='LINK')R.fix()},true)}" ++
        "R.s=s;R.fix();return s||'os'})('" ++ s ++ "')";
}

const testing = std.testing;

test "T3720: on glass a template page takes the terminal background's scheme, whatever the desktop says" {
    const light_bg: color_math.Rgb = .{ .r = 0xF0, .g = 0xF0, .b = 0xF0 };
    const dark_bg: color_math.Rgb = .{ .r = 0x20, .g = 0x30, .b = 0x40 };
    try testing.expectEqual(@as(?Scheme, .light), forced(true, .markdown, light_bg));
    try testing.expectEqual(@as(?Scheme, .dark), forced(true, .markdown, dark_bg));
    inline for (.{ .code, .diff, .image }) |m| {
        try testing.expectEqual(@as(?Scheme, .light), forced(true, m, light_bg));
    }
}

test "T3720: off glass, and for a website or an html file, the page follows the app style" {
    const light_bg: color_math.Rgb = .{ .r = 0xF0, .g = 0xF0, .b = 0xF0 };
    try testing.expectEqual(@as(?Scheme, null), forced(false, .markdown, light_bg));
    try testing.expectEqual(@as(?Scheme, null), forced(true, .web, light_bg));
    try testing.expectEqual(@as(?Scheme, null), forced(true, .html, light_bg));
}

test "T3720: a held style sheet request names its scheme in the query" {
    try testing.expectEqual(@as(?Scheme, .dark), schemeFromQuery("ghoztty-viewer://page/viewer.css?gz-scheme=dark"));
    try testing.expectEqual(@as(?Scheme, .light), schemeFromQuery("ghoztty-viewer://page/vendor/x.css?v=1&gz-scheme=light"));
    try testing.expectEqual(@as(?Scheme, null), schemeFromQuery("ghoztty-viewer://page/viewer.css"));
    try testing.expectEqual(@as(?Scheme, null), schemeFromQuery("ghoztty-viewer://page/viewer.css?gz-scheme=blue"));
    try testing.expectEqual(@as(?Scheme, null), schemeFromQuery("ghoztty-viewer://page/viewer.css?other=dark"));
}

test "T3720: the CSS rewrite answers every prefers-color-scheme condition and leaves the rest" {
    const a = testing.allocator;
    const css =
        "@media (prefers-color-scheme: dark) { a { color: #fff } }\n" ++
        "@media ( PREFERS-COLOR-SCHEME:light ){b{}}\n" ++
        "@media screen and (prefers-color-scheme: dark), print {c{}}\n" ++
        "@media (prefers-reduced-motion: reduce) {d{}} e { width: calc(1px + (2px)) }";
    const dark = try rewriteCss(a, css, .dark);
    defer a.free(dark);
    try testing.expectEqualStrings(
        "@media (min-width:0px) { a { color: #fff } }\n" ++
            "@media (max-width:-1px){b{}}\n" ++
            "@media screen and (min-width:0px), print {c{}}\n" ++
            "@media (prefers-reduced-motion: reduce) {d{}} e { width: calc(1px + (2px)) }",
        dark,
    );
    const light = try rewriteCss(a, css, .light);
    defer a.free(light);
    try testing.expect(std.mem.startsWith(u8, light, "@media (max-width:-1px) {"));
    try testing.expect(std.mem.indexOf(u8, light, "prefers-color-scheme") == null);
}

test "T3720: the page script names the scheme it holds, and a release names none" {
    try testing.expect(std.mem.endsWith(u8, applyJs(.light), "('light')"));
    try testing.expect(std.mem.endsWith(u8, applyJs(.dark), "('dark')"));
    try testing.expect(std.mem.endsWith(u8, applyJs(null), "('')"));
    // A release on a page that was never held installs nothing.
    try testing.expect(std.mem.indexOf(u8, applyJs(null), "if(!s)return 'os'") != null);
}
