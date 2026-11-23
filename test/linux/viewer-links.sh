#!/usr/bin/env bash
# viewer-links.sh - L9f (T3415) acceptance: where a link clicked in a GTK
# viewer pane goes, where a popup goes, and what the right-click link menu
# offers.
#
#   markdown/code: http(s) -> the default browser; a relative .md/.html link
#     -> a viewer split beside the pane; any other file -> its default app; a
#     link to nothing, or mailto:, does nothing; a ghoztty link focuses in
#     this app.
#   live pages (a rendered .html, a website): a link on the page's own site
#     follows in the pane (host + port as written; for a rendered page, its
#     own folder); a click off it takes the banner's scheme - plain to the
#     browser, Ctrl a side pane, Ctrl+Shift a window of its own; a file://
#     link is revealed.
#   popups (target=_blank, window.open): the default browser; one that must
#     stay in Ghoztty (a bare window.open, a non-web scheme) is adopted as a
#     viewer window of its own (T3447): its page sees window.opener, the
#     opener can write into a blank one, width/height size the window, and
#     window.close() closes it.
#   the link menu: links.js in every frame decides; it declines a #fragment
#     and mailto:, the rows are banner_link's, a file link's target is the
#     FILE, and a row runs its action.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-links.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh).
# Weston headless has no seat, so clicks are the page's own: a dispatched
# click MouseEvent, which WebKit reports as the same LINK_CLICKED navigation a
# pointer click is. WebKit deliberately drops the modifiers of a script-made
# click (a page must not fake a Ctrl-click), so the steps' `mods ctrl` /
# `mods ctrl+shift` stand in for the keyboard; reading a real click's
# modifiers off WebKit is the one thing not exercised here.
# Nothing ever leaves the app: the debug build's GHOZTTY_TEST_VIEWER_LINKS sink
# records every hand-off to the browser or a default app INSTEAD of running it
# (inside WSL xdg-open can reach the Windows browser), and a test run without
# the sink refuses them. The menu cannot pop up without a seat, so the sink
# records the rows it would show and the steps' `menu-pick` runs one.
#
# Output: one PASS/FAIL line per check, then 'VIEWER LINKS: ALL PASS' or
# 'VIEWER LINKS: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER LINKS"

log=/tmp/viewer-links-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "K1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "K2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixtures --------------------------------------------------------------
fx="$HL_RUNTIME/fx"
mkdir -p "$fx/sub" "$fx/site"
cat > "$fx/doc.md" <<'EOF'
# Links One

[web](https://example.test/x)
[other](other.md)
[page](page.html)
[code](code.zig)
[missing](nope.md)
[mail](mailto:a@b.test)
[top](#links-one)
[focus](ghoztty-debug://focus/termwin)
EOF
printf '# Other Doc\n' > "$fx/other.md"
printf 'const x = 1;\n' > "$fx/code.zig"
cat > "$fx/page.html" <<'EOF'
<!DOCTYPE html><html><head><title>Page</title></head><body><h1>Page One</h1>
<a id="sib" href="sub/two.html">sib</a>
<a id="out" href="https://example.test/out">out</a>
<a id="file" href="file:///etc/hostname">file</a>
<a id="blank" target="_blank" href="https://example.test/pop">blank</a>
<a id="sameblank" target="_blank" href="sub/two.html">sameblank</a>
<iframe id="fr" src="frame.html"></iframe>
<script>addEventListener("message",function(e){if(typeof e.data==="string"&&e.data.indexOf("fromPop|")===0)(window.__fromPop=window.__fromPop||[]).push(e.data)})</script>
</body></html>
EOF
printf '<!DOCTYPE html><html><body><a id="fl" href="https://example.test/framed">framed</a><script>addEventListener("message",function(){document.getElementById("fl").dispatchEvent(new MouseEvent("contextmenu",{bubbles:true,cancelable:true}))})</script></body></html>
' > "$fx/frame.html"
# Pages served from a custom scheme are cross-origin to each other, so an
# adopted popup (T3447) reports to its opener, and is told to close, by
# postMessage - which only reaches it through a real window.opener.
cat > "$fx/sub/two.html" <<'EOF'
<!DOCTYPE html><html><body><h1>Page Two</h1><script>
addEventListener("load",function(){setTimeout(function(){if(window.opener)window.opener.postMessage("fromPop|"+window.name+"|"+document.querySelector("h1").textContent+"|"+innerWidth,"*")},500)});
addEventListener("message",function(e){if(e.data==="close")window.close()});
</script></body></html>
EOF

port=$((20000 + $$ % 20000))
port2=$((port + 1))
cat > "$fx/site/index.html" <<EOF
<!DOCTYPE html><html><body><h1>Site Up</h1>
<a id="same" href="/two.html">same</a>
<a id="port" href="http://127.0.0.1:$port2/">port</a>
<a id="host" href="http://localhost:$port/">host</a>
<a id="cmd" href="ghoztty-debug://focus/termwin">cmd</a>
<a id="popsame" target="_blank" href="/two.html">popsame</a>
</body></html>
EOF
printf '<!DOCTYPE html><html><body><h1>Site Two</h1></body></html>\n' > "$fx/site/two.html"
(cd "$fx/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) > "$HL_RUNTIME/http.log" 2>&1 &
HTTP_PID=$!
HL_PIDS="$HL_PIDS $HTTP_PID"
hl_wait_for 10 sh -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }
# Every leaf of every window: type|url|name, one per line.
leaves() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            print("%s|%s|%s|%s" % (w.get("target") or "", l.get("type"), l.get("url") or "", l.get("name") or ""))
' 2>/dev/null
}

H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"
# click <selector> [ctrl] [shift]: the page's own click on a link.
click() {
    local sel="$1" ctrl="${2:-false}" shift="${3:-false}"
    echo "probe (function(){var a=document.querySelector('$sel');if(!a)return 'NOLINK';a.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,ctrlKey:$ctrl,shiftKey:$shift}));return 'clicked'})()"
}
# menu <selector>: a right-click on it, as links.js sees one.
menu() {
    echo "probe (function(){var a=document.querySelector('$1');if(!a)return 'NOLINK';var ok=a.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}));return ok?'kept':'suppressed'})()"
}

# ---- the steps the first pane runs once it has rendered --------------------
steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
sink="$HL_RUNTIME/links.out"
{
    echo "mark md"
    click 'a[href="https://example.test/x"]'
    click 'a[href="other.md"]'
    echo "sleep 1500"
    click 'a[href="page.html"]'
    echo "sleep 1500"
    click 'a[href="code.zig"]'
    click 'a[href="nope.md"]'
    click 'a[href="mailto:a@b.test"]'
    click 'a[href="ghoztty-debug://focus/termwin"]'
    echo "sleep 500"
    echo "state"
    echo "mark md-menu"
    menu 'a[href="other.md"]'
    menu 'a[href="https://example.test/x"]'
    menu 'a[href="#links-one"]'
    menu 'a[href="mailto:a@b.test"]'
    menu 'a[href="nope.md"]'
    echo "menu-pick copy"
    echo "menu-pick reveal"
    echo "mark html"
    echo "key <Control>l"
    echo "type $fx/page.html"
    echo "activate"
    echo "wait"
    echo "probe $H"
    click '#out'
    echo "sleep 300"
    echo "mods ctrl"
    click '#out'
    echo "sleep 300"
    echo "mods none"
    click '#file'
    echo "sleep 300"
    echo "mods ctrl+shift"
    click '#file'
    echo "sleep 300"
    echo "mods none"
    click '#blank'
    echo "sleep 500"
    echo "mods ctrl"
    click '#sameblank'
    echo "sleep 500"
    echo "mods none"
    echo "probe (function(){window.open('https://example.test/opened');window.open();return 'opened'})()"
    # Adopted popups (T3447): a page-relative one at a requested size, and a
    # bare one the opener writes into; then the page closes the first.
    echo "mark popups"
    echo "probe (function(){var w=window.open('sub/two.html','sized','width=500,height=400');window.__pop=w;return w?'adopted':'null'})()"
    echo "probe (function(){return window.open('sub/two.html','plain')?'plain adopted':'plain null'})()"
    echo "sleep 3000"
    echo "probe (function(){return 'pop '+(window.__fromPop||[]).join(' ')})()"
    echo "probe (function(){var w=window.open();if(!w)return 'blank null';w.document.write('<h1>Written</h1>');w.document.close();window.__blank=w;return 'blank wrote'})()"
    echo "sleep 1000"
    echo "probe (function(){try{var w=window.__blank;return 'blankread '+w.document.querySelector('h1').textContent+'|'+(w.opener===window)}catch(e){return 'blankread ERR '+e}})()"
    echo "mark popups-open"
    echo "sleep 4000"
    echo "probe (function(){window.__pop.postMessage('close','*');return 'closing'})()"
    echo "sleep 2000"
    echo "probe (function(){return 'closed '+window.__pop.closed})()"
    echo "mark popups-closed"
    echo "sleep 4000"
    menu '#out'
    echo "probe (function(){document.getElementById('fr').contentWindow.postMessage('rc','*');return 'posted'})()"
    menu '#sib'
    echo "sleep 500"
    click '#sib'
    echo "wait"
    echo "probe $H"
    echo "state"
    echo "mark web"
    echo "key <Control>l"
    echo "type 127.0.0.1:$port/"
    echo "activate"
    echo "wait"
    echo "probe $H"
    click '#port'
    echo "sleep 300"
    echo "mods ctrl"
    click '#port'
    echo "sleep 300"
    echo "mods ctrl+shift"
    click '#port'
    echo "sleep 300"
    echo "mods none"
    click '#host'
    click '#cmd'
    echo "mods ctrl"
    click '#popsame'
    echo "sleep 1500"
    echo "mods none"
    echo "sleep 1500"
    echo "state"
    click '#same'
    echo "wait"
    echo "probe $H"
    echo "state"
    echo "sleep 1500"
} > "$steps"

dump="$HL_RUNTIME/viewer-dump"
export SHELL=/bin/sh
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="$H"
export GHOZTTY_TEST_VIEWER_STEPS="$steps"
export GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
export GHOZTTY_TEST_VIEWER_LINKS="$sink"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT GHOZTTY_TEST_VIEWER_LINKS
hl_wait_for 30 test -S "$sock"
hl_check "K3 the app serves its socket" $?

o=$(cli +new-window --target=termwin 2>&1)
hl_check "K4 a terminal window named termwin is up (the ghoztty link's target)" $? "$o"
o=$(cli +split --view=doc.md --name=doc 2>&1)
hl_check "K5 +split --view=doc.md opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(head -1 "$dump" 2>/dev/null)" = "OK Links One" ]
hl_check "K6 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

hl_wait_for 60 grep -q '^mark html' "$out"
md_leaves=$(leaves)
hl_wait_for 90 grep -q '^mark popups-open' "$out"
pop_leaves=$(leaves)
hl_wait_for 30 grep -q '^mark popups-closed' "$out"
closed_leaves=$(leaves)
hl_wait_for 90 grep -q '^done' "$out"
hl_check "K7 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"
sleep 1
all_leaves=$(leaves)

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
st() { nth state "$1"; }
pr() { nth "probe OK" "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
sunk() { grep -qxF "$1" "$sink" 2>/dev/null; }

# ---- markdown -------------------------------------------------------------
sunk "browser https://example.test/x"
hl_check "K8 a markdown http(s) link goes to the default browser" $? "$(head -5 "$sink" 2>/dev/null | tr '\n' ' ')"
sunk "split $fx/other.md" && echo "$md_leaves" | grep -qF "|viewer|$fx/other.md|"
hl_check "K9 a relative .md link opens a viewer split showing it" $? "$(echo "$md_leaves" | tr '\n' ' ')"
sunk "split $fx/page.html" && echo "$md_leaves" | grep -qF "|viewer|$fx/page.html|"
hl_check "K10 a relative .html link opens a viewer split too (it renders here)" $? "$(echo "$md_leaves" | tr '\n' ' ')"
sunk "app $fx/code.zig"
hl_check "K11 any other file opens in its default app" $? "$(grep '^app' "$sink" 2>/dev/null | tr '\n' ' ')"
! grep -qE '^(split|app|browser|window) .*(nope\.md|mailto)' "$sink" 2>/dev/null &&
    grep -q "viewer: link names no existing file: nope.md" "$APP_LOG"
hl_check "K12 a link to a missing file, and a mailto:, do nothing (the missing one is logged)" $? "$(grep -E 'nope|mailto' "$sink" "$APP_LOG" 2>/dev/null | head -3 | tr '\n' ' ')"
sunk "focus ghoztty-debug://focus/termwin" && grep -q "viewer link: focus termwin: " "$APP_LOG"
hl_check "K13 a ghoztty link focuses its target in THIS app" $? "$(grep -m2 'viewer link: focus' "$APP_LOG" | tr '\n' ' ')"
has "$(st 1)" "mode=markdown current=$fx/doc.md "
hl_check "K14 none of those clicks moved the pane" $? "$(st 1)"

# ---- the link menu ---------------------------------------------------------
grep -qxF "menu file $fx/other.md rows=reveal|side_pane,new_window|open_default_app|copy" "$sink"
hl_check "K15 a relative doc link's menu acts on the FILE: reveal first, then side pane / window, app, Copy Path" $? "$(grep '^menu' "$sink" | tr '\n' ' ')"
grep -qxF "menu web https://example.test/x rows=open_browser|side_pane,new_window|copy" "$sink"
hl_check "K16 a web link's menu: browser first, then side pane / window, Copy Link" $? "$(grep '^menu' "$sink" | tr '\n' ' ')"
! grep -qE '^menu .*(#links-one|mailto)' "$sink" && [ "$(grep -c '^probe OK kept' "$out")" -ge 2 ]
hl_check "K17 a #fragment and a mailto: keep WebKit's menu (no Ghoztty menu)" $? "$(grep '^menu' "$sink" | tr '\n' ' ')"
grep -qxF "menu file $fx/nope.md rows=reveal|side_pane,new_window|open_default_app|copy" "$sink"
hl_check "K18 a broken doc link still gets the menu, naming the file it meant" $? "$(grep '^menu' "$sink" | tr '\n' ' ')"
sunk "copy $fx/nope.md" && sunk "reveal $fx/nope.md"
hl_check "K19 menu rows run their action on the armed target (Copy Path, Open Containing Folder)" $? "$(grep -E '^(copy|reveal)' "$sink" | tr '\n' ' ')"

# ---- a rendered .html page -------------------------------------------------
sunk "browser https://example.test/out"
hl_check "K20 a rendered page's link off its folder goes to the browser" $? "$(grep '^browser' "$sink" | tr '\n' ' ')"
sunk "split https://example.test/out"
hl_check "K21 Ctrl on that link opens a side pane instead" $? "$(grep '^split' "$sink" | tr '\n' ' ')"
sunk "reveal /etc/hostname" && sunk "app /etc/hostname"
hl_check "K22 a file:// link off a page is revealed, not opened; Ctrl+Shift hands it to its app" $? "$(grep -E '^(reveal|app)' "$sink" | tr '\n' ' ')"
sunk "browser https://example.test/pop" && sunk "browser https://example.test/opened"
hl_check "K23 a target=_blank link and window.open(url) go to the default browser" $? "$(grep '^browser' "$sink" | tr '\n' ' ')"
grep -q 'viewer: popup adopted location=about:blank' "$APP_LOG" &&
    grep -q "viewer: popup adopted location=ghoztty-page://page/sub/two.html" "$APP_LOG" &&
    ! grep -q 'not adopted' "$APP_LOG"
hl_check "K24 a popup that must stay in Ghoztty (bare window.open, a Ctrl-clicked same-site one) is adopted" $? "$(grep 'popup' "$APP_LOG" | tr '\n' ' ')"
# T3447: the adopted popups themselves.
grep -qx 'probe OK adopted' "$out" && grep -q '^probe OK pop .*fromPop|sized|Page Two|' "$out"
hl_check "K24a window.open into the page's folder gets a window whose page sees window.opener" $? "$(grep -E '^probe .*(adopted|pop )' "$out" | tr '\n' ' ')"
[ "$(echo "$pop_leaves" | grep -cF "|viewer|$fx/sub/two.html|")" -ge 2 ] && echo "$pop_leaves" | grep -qF "|viewer|about:blank|"
hl_check "K24b the adopted popups are viewer windows of their own (+list)" $? "$(echo "$pop_leaves" | tr '\n' ' ')"
grep -qx 'probe OK blankread Written|true' "$out"
hl_check "K24c a bare window.open() hands back a window the opener writes into" $? "$(grep -E '^probe .*blank' "$out" | tr '\n' ' ')"
w=$(grep -o 'fromPop|sized|Page Two|[0-9]*' "$out" | head -1 | awk -F'|' '{print $4}')
[ -n "$w" ] && [ "$w" -ge 440 ] && [ "$w" -le 500 ] && grep -q 'viewer: popup ready to show at 500x400 (asked 500x400)' "$APP_LOG" && grep -q 'viewer: popup ready to show at the default size' "$APP_LOG"
hl_check "K24d width=500,height=400 opens the window at that size, and a popup that asked for none gets the default (page innerWidth $w)" $? "$(grep 'ready to show' "$APP_LOG" | tr '\n' ' ')"
before=$(echo "$pop_leaves" | grep -cF "|viewer|$fx/sub/two.html|")
after=$(echo "$closed_leaves" | grep -cF "|viewer|$fx/sub/two.html|")
grep -qx 'probe OK closed true' "$out" && [ "$after" = $((before - 1)) ] && grep -q 'viewer popup: the page closed its pane' "$APP_LOG"
hl_check "K24e window.close() in the popup closes its window (two.html windows $before -> $after)" $? "$(grep -E 'closed|asked to close' "$out" "$APP_LOG" | tr '\n' ' ')"
grep -q "viewer: popup adopted location=http://127.0.0.1:$port/two.html" "$APP_LOG" && echo "$all_leaves" | grep -qF "|viewer|http://127.0.0.1:$port/two.html|"
hl_check "K24f a Ctrl-clicked same-site target=_blank link on a website is adopted as a viewer window too" $? "$(grep "popup.*$port/two" "$APP_LOG" | tr '\n' ' ')"
grep -qxF "menu web https://example.test/out rows=open_browser|side_pane,new_window|copy" "$sink"
hl_check "K25 a rendered page's link gets Ghoztty's menu" $? "$(grep '^menu' "$sink" | tr '\n' ' ')"
grep -qxF "menu web https://example.test/framed rows=open_browser|side_pane,new_window|copy" "$sink"
hl_check "K26 a link inside an iframe gets it too (links.js runs in every frame)" $? "$(grep '^menu' "$sink" | tr '\n' ' ')"
grep -qxF "menu file $fx/sub/two.html rows=reveal|side_pane,new_window|open_default_app|copy" "$sink"
hl_check "K27 a page-relative link's menu acts on the file under the page's folder" $? "$(grep '^menu' "$sink" | tr '\n' ' ')"
has "$(st 2)" "mode=html current=$fx/sub/two.html " && grep -qx 'probe OK Page Two' "$out"
hl_check "K28 a link inside the page's own folder follows in the pane" $? "$(st 2)"

# ---- a website -------------------------------------------------------------
sunk "browser http://127.0.0.1:$port2/" && sunk "split http://127.0.0.1:$port2/" && sunk "window http://127.0.0.1:$port2/"
hl_check "K29 a website's link to another port: plain -> browser, Ctrl -> side pane, Ctrl+Shift -> window" $? "$(grep "$port2" "$sink" | tr '\n' ' ')"
sunk "browser http://localhost:$port/"
hl_check "K30 another host is another site" $? "$(grep localhost "$sink" | tr '\n' ' ')"
[ "$(grep -c '^focus ghoztty-debug://focus/termwin' "$sink")" = 2 ]
hl_check "K31 a ghoztty link on a website is answered in this app too" $? "$(grep '^focus' "$sink" | tr '\n' ' ')"
has "$(st 3)" "mode=web current=http://127.0.0.1:$port/ "
hl_check "K32 none of the off-site clicks moved the pane" $? "$(st 3)"
has "$(st 4)" "current=http://127.0.0.1:$port/two.html " && grep -qx 'probe OK Site Two' "$out"
hl_check "K33 a same-site link follows in the pane" $? "$(st 4)"
echo "$all_leaves" | grep -qF "|viewer|http://127.0.0.1:$port2/|"
hl_check "K34 the Ctrl / Ctrl+Shift opens really opened viewers (a split and a window)" $? "$(echo "$all_leaves" | tr '\n' ' ')"

# ---- nothing escaped -------------------------------------------------------
! grep -q 'refused to hand' "$APP_LOG" && ! grep -q 'viewer: open in browser\|viewer: open with default app' "$APP_LOG"
hl_check "K35 no hand-off reached the desktop: every one was recorded by the sink" $? "$(grep -E 'refused to hand|open in browser|default app' "$APP_LOG" | head -3 | tr '\n' ' ')"
grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "K36 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- sink ----"
    cat "$sink" 2>/dev/null
    echo "---- leaves ----"
    echo "$all_leaves"
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -60
fi

hl_finish "$L"
