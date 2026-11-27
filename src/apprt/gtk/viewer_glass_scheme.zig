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

fn script(comptime s: []const u8) []const u8 {
    return "(function(s){var R=window.__gzScheme;if(!R){if(!s)return 'os';" ++
        "R=window.__gzScheme={m:new Map(),s:''};" ++
        "R.q=function(o){return R.s?o.replace(/\\(\\s*prefers-color-scheme\\s*:\\s*(light|dark)\\s*\\)/gi," ++
        "function(_,v){return v.toLowerCase()===R.s?'(min-width:0px)':'(max-width:-1px)'}):o};" ++
        "R.one=function(l){if(!l)return;var o=R.m.get(l);if(o===undefined){o=l.mediaText;" ++
        "if(!/prefers-color-scheme/i.test(o))return;R.m.set(l,o)}var n=R.q(o);if(l.mediaText!==n)l.mediaText=n};" ++
        "R.walk=function(rs){if(!rs)return;for(var i=0;i<rs.length;i++){var r=rs[i];if(r.media)R.one(r.media);" ++
        "if(r.cssRules)R.walk(r.cssRules)}};" ++
        "R.fix=function(){var ss=document.styleSheets;for(var i=0;i<ss.length;i++){var sh=ss[i];R.one(sh.media);" ++
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

test "T3720: the page script names the scheme it holds, and a release names none" {
    try testing.expect(std.mem.endsWith(u8, applyJs(.light), "('light')"));
    try testing.expect(std.mem.endsWith(u8, applyJs(.dark), "('dark')"));
    try testing.expect(std.mem.endsWith(u8, applyJs(null), "('')"));
    // A release on a page that was never held installs nothing.
    try testing.expect(std.mem.indexOf(u8, applyJs(null), "if(!s)return 'os'") != null);
}
