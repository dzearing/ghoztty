#!/usr/bin/env bash
# viewer-nav.sh - L9c (T3412) acceptance: a GTK viewer pane's navigation bar
# and pane keys. The bar is there from the first frame with back / forward /
# reload / home, an editable address, and a reveal button only while a local
# file is shown; a typed address navigates (an absolute path to a file, a bare
# host omnibox-completed to the web); history walks across the file <-> web
# boundary and re-renders the file it left; Home returns to the opened
# location; Ctrl+L selects the address, Escape reverts a half-typed one,
# Ctrl+R reloads a file in place, Ctrl +/-/0 zoom; chords the pane does not
# own are declined; +list follows where the pane IS. Run it ONLY through the
# wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-nav.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh). Weston headless has
# no seat and Wayland no input injection, so the bar and the keys are driven
# by the debug build's GHOZTTY_TEST_VIEWER_STEPS seam (src/apprt/gtk/Viewer.zig):
# the same key handler the pane's capture-phase controller calls, and the
# buttons' own `clicked`. Only GDK's delivery of a physical press is not here.
#
# Output: one PASS/FAIL line per check, then 'VIEWER NAV: ALL PASS' or
# 'VIEWER NAV: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER NAV"

log=/tmp/viewer-nav-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "N1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "N2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixtures --------------------------------------------------------------
fx="$HL_RUNTIME/fx"
mkdir -p "$fx/site"
printf '# Nav One\n\ntext\n' > "$fx/doc.md"
printf '# Nav Two\n' > "$fx/other.md"
printf '<!DOCTYPE html><html><body><h1>Site Up</h1></body></html>\n' > "$fx/site/index.html"
port=$((20000 + $$ % 20000))
(cd "$fx/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) > "$HL_RUNTIME/http.log" 2>&1 &
HTTP_PID=$!
HL_PIDS="$HL_PIDS $HTTP_PID"
hl_wait_for 10 sh -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }
leaf() {
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
            if l.get("name") == sys.argv[1]:
                print("%s|%s|%s" % (l.get("type"), l.get("url") or "", l.get("title") or ""))
' "$1" 2>/dev/null
}

H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"

# ---- the steps the pane runs once it has rendered --------------------------
steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
state
key <Control>l
state
type $fx/other.md
activate
wait
probe $H
state
key <Control>l
type 127.0.0.1:$port/
activate
wait
probe $H
state
mark web
sleep 2500
click back
wait
probe $H
state
click back
wait
probe $H
state
click forward
wait
probe $H
click home
wait
probe $H
state
key <Control>l
type something half typed
key Escape
state
key <Control>equal
key <Control>equal
state
key <Control>minus
state
key <Control>0
state
key <Control><Shift>r
key <Control>d
key <Control>f
key <Control>g
key <Alt>d
state
mark edit
sleep 2500
key <Control>r
wait
probe $H
click reload
wait
probe $H
click reveal
mark gone
sleep 2500
state
click reveal
sleep 500
EOF

dump="$HL_RUNTIME/viewer-dump"
export SHELL=/bin/sh
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="$H"
export GHOZTTY_TEST_VIEWER_STEPS="$steps"
export GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT
hl_wait_for 30 test -S "$sock"
hl_check "N3 the app serves its socket" $?

o=$(cli +split --view=doc.md --name=doc 2>&1)
hl_check "N4 +split --view=doc.md opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK Nav One" ]
hl_check "N5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

# The driving script's half of the sync points.
hl_wait_for 60 grep -q '^mark web' "$out"
web_leaf=$(leaf doc)
hl_wait_for 60 grep -q '^mark edit' "$out"
printf '# Nav Edited\n' > "$fx/doc.md"
hl_wait_for 60 grep -q '^mark gone' "$out"
rm -f "$fx/doc.md"
hl_wait_for 60 grep -q '^done' "$out"
hl_check "N6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

# line <n>: the n-th line of the steps' output whose verb is <verb>.
nth() { grep "^$1" "$out" | sed -n "${2}p"; }
st() { nth state "$1"; }
pr() { nth probe "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

s=$(st 1)
has "$s" "mode=markdown current=$fx/doc.md address=$fx/doc.md back=false forward=false reveal=true zoom=1.000" &&
    [ "${s##*barh=}" -gt 0 ] 2>/dev/null
hl_check "N7 the bar is there from the first render: address = the file, no history, reveal shown, height reserved" $? "$s"

s=$(st 2); n=$(printf '%s' "$fx/doc.md" | wc -c)
has "$s" "focus=address sel=0-$n"
hl_check "N8 Ctrl+L puts the caret in the address with all of it selected" $? "$s"

[ "$(pr 1)" = "probe OK Nav Two" ] && has "$(st 3)" "mode=markdown current=$fx/other.md address=$fx/other.md back=true forward=false"
hl_check "N9 an absolute path typed into the address opens that file (history gains an entry)" $? "$(pr 1) / $(st 3)"

s=$(st 4)
[ "$(pr 2)" = "probe OK Site Up" ] && has "$s" "mode=web current=http://127.0.0.1:$port/ address=http://127.0.0.1:$port/ back=true forward=false reveal=false"
hl_check "N10 a bare host:port is completed to http:// and the pane goes to the web; no reveal on a website" $? "$(pr 2) / $s"

[ "$(echo "$web_leaf" | cut -d'|' -f2)" = "http://127.0.0.1:$port/" ] && [ "$(echo "$web_leaf" | cut -d'|' -f3)" = "127.0.0.1" ]
hl_check "N11 +list follows the pane: url is the website, title its host" $? "leaf: $web_leaf"

[ "$(pr 3)" = "probe OK Nav Two" ] && has "$(st 5)" "mode=markdown current=$fx/other.md address=$fx/other.md back=true forward=true reveal=true"
hl_check "N12 Back from the website re-renders the file it left" $? "$(pr 3) / $(st 5)"

[ "$(pr 4)" = "probe OK Nav One" ] && has "$(st 6)" "current=$fx/doc.md " && has "$(st 6)" "back=false forward=true"
hl_check "N13 Back again walks to the first file; nothing left behind it" $? "$(pr 4) / $(st 6)"

[ "$(pr 5)" = "probe OK Nav Two" ]
hl_check "N14 Forward walks history the other way" $? "$(pr 5)"

[ "$(pr 6)" = "probe OK Nav One" ] && has "$(st 7)" "current=$fx/doc.md address=$fx/doc.md"
hl_check "N15 Home returns to the location the pane was opened with" $? "$(pr 6) / $(st 7)"

s=$(st 8)
has "$s" "address=$fx/doc.md" && has "$s" "focus=content"
hl_check "N16 Escape throws a half-typed address away and hands focus back to the page" $? "$s"

has "$(st 9)" "zoom=1.210" && has "$(st 10)" "zoom=1.100" && has "$(st 11)" "zoom=1.000"
hl_check "N17 Ctrl+= zooms in by the Mac's step, Ctrl+- out, Ctrl+0 resets" $? "$(st 9) / $(st 10) / $(st 11)"

k=$(grep '^key' "$out")
echo "$k" | grep -q '^key <Control>l handled=true' &&
    echo "$k" | grep -q '^key Escape handled=true' &&
    echo "$k" | grep -q '^key <Control>equal handled=true'
hl_check "N18 the pane claims its own chords" $? "$(echo "$k" | tr '\n' ' ')"
echo "$k" | grep -q '^key <Control><Shift>r handled=false' &&
    echo "$k" | grep -q '^key <Control>d handled=false' &&
    echo "$k" | grep -q '^key <Control>f handled=false' &&
    echo "$k" | grep -q '^key <Control>g handled=false'
hl_check "N19 Ctrl+Shift+R, Ctrl+D (split) and find (T3414) are declined, so they fall through" $? "$(echo "$k" | tr '\n' ' ')"
echo "$k" | grep -q '^key <Alt>d handled=true' && has "$(st 12)" "focus=address"
hl_check "N20 Alt+D focuses the address too (the browser pair)" $? "$(st 12)"

[ "$(pr 7)" = "probe OK Nav Edited" ]
hl_check "N21 Ctrl+R re-reads the file in place" $? "$(pr 7)"
[ "$(pr 8)" = "probe OK Nav Edited" ]
hl_check "N22 the reload button reloads the pane" $? "$(pr 8)"

grep -q "viewer: reveal file=$fx/doc.md" "$APP_LOG"
hl_check "N23 the reveal button asks the file manager for the file" $? "$(grep -m2 'reveal' "$APP_LOG" | tr '\n' ' ')"
grep -q "viewer: reveal folder=$fx (the file is gone)" "$APP_LOG"
hl_check "N24 a file deleted under the pane reveals its nearest existing folder" $? "$(grep 'reveal' "$APP_LOG" | tr '\n' ' ')"

l=$(leaf doc)
[ "$l" = "viewer|$fx/doc.md|doc.md" ]
hl_check "N25 +list reads the pane back on its home file, titled by it" $? "leaf: $l"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "N26 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -40
fi

hl_finish "$L"
