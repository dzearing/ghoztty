#!/usr/bin/env bash
# viewer-reload.sh - L9d (T3413) acceptance: a GTK viewer pane's reloads.
#
# - Live reload: a markdown pane re-renders when its file is saved - in place
#   and atomically (temp file renamed over it) - keeping the scroll; a deleted
#   file shows the unreadable card, and re-creating it brings the document
#   back. A local .html page reloads in place on a save, keeping the scroll;
#   an edited sibling stylesheet does NOT reload it (only the viewed file is
#   watched), and `+reload` picks the stylesheet up.
# - `+reload` reloads a viewer pane; its refusals are win32's sentences (a
#   terminal pane, a window focused on a terminal, a missing name, --config
#   with --target); --config itself reloads the app config (T3369, whose
#   effect cli-reload.sh proves).
# - Ctrl+R on a website re-fetches it.
# - A dead web process: a real SIGKILL and WebKit's own termination each
#   reload the page, at most 3 times a minute (Mac contentProcessRestartLimit);
#   the 4th shows "This page keeps crashing", and Ctrl+R then loads the page
#   again.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-reload.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh); the pane is driven
# and read back through the debug build's GHOZTTY_TEST_VIEWER_STEPS seam
# (src/apprt/gtk/Viewer.zig), and the driving script edits the fixtures at
# the steps' `mark` sync points.
#
# Output: one PASS/FAIL line per check, then 'VIEWER RELOAD: ALL PASS' or
# 'VIEWER RELOAD: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER RELOAD"

log=/tmp/viewer-reload-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "R1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "R2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixtures --------------------------------------------------------------
fx="$HL_RUNTIME/fx"
mkdir -p "$fx/page" "$fx/site"
body() { i=1; while [ $i -le 150 ]; do printf 'Paragraph %d of a long document.\n\n' $i; i=$((i + 1)); done; }
# Each fixture is built aside and lands in ONE write (cat), so a save is one
# burst of events however slow the shell loop that built it was.
md() { { printf '# %s\n\n' "$1"; body; } > "$HL_RUNTIME/build.tmp" && cat "$HL_RUNTIME/build.tmp" > "$2"; }
md "Live Zero" "$fx/doc.md"
page() {
    { printf '<!DOCTYPE html><html><head><link rel="stylesheet" href="style.css"></head><body><h1>%s</h1>\n' "$1"
      i=1; while [ $i -le 150 ]; do printf '<p>Line %d</p>\n' $i; i=$((i + 1)); done
      printf '</body></html>\n'; } > "$HL_RUNTIME/page.tmp" && cat "$HL_RUNTIME/page.tmp" > "$fx/page/index.html"
}
page "Page Zero"
printf 'h1 { color: rgb(255, 0, 0); }\n' > "$fx/page/style.css"
printf '<!DOCTYPE html><html><body><h1>Site Zero</h1></body></html>\n' > "$fx/site/index.html"
port=$((20000 + $$ % 20000))
(cd "$fx/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) > "$HL_RUNTIME/http.log" 2>&1 &
HTTP_PID=$!
HL_PIDS="$HL_PIDS $HTTP_PID"
hl_wait_for 10 sh -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

# The page's heading, and the page's heading with its scroll offset.
H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"
HS="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return (h?h.textContent:'NOH1')+'|'+Math.round(window.scrollY)})()"
COLOR="getComputedStyle(document.querySelector('h1')).color"

# ---- the steps the pane runs once it has rendered --------------------------
# A `sleep` before each scroll probe: the template restores the scroll on the
# next animation frame after a re-render (src/viewer/viewer.js restoreScroll),
# and WebKit restores a reloaded page's after its load finishes.
steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
probe window.scrollTo(0, 600); Math.round(window.scrollY)
sleep 300
probe Math.round(window.scrollY)
mark inplace
wait
sleep 400
probe $HS
mark atomic
wait
sleep 400
probe $HS
probe window.scrollTo(0, 600); Math.round(window.scrollY)
mark slow
wait
wait
sleep 400
probe $HS
mark rm
wait
probe document.body.innerText.indexOf('Cannot read file') >= 0
mark recreate
wait
probe $H
mark cli-reload
wait
probe $H
mark kill
wait
probe $H
state
terminate
wait
terminate
wait
state
terminate
wait
probe document.getElementById('ghoztty-crashed') ? (document.getElementById('ghoztty-crashed').textContent + '|' + document.body.innerText).replace(/\s+/g, ' ') : 'NOCARD'
state
key <Control>r
wait
probe $H
state
key <Control>l
type $fx/page/index.html
activate
wait
sleep 300
probe window.scrollTo(0, 500); Math.round(window.scrollY)
mark page-save
wait
sleep 500
probe $HS
probe $COLOR
mark css
sleep 1500
probe $COLOR
mark page-reload
wait
sleep 300
probe $COLOR
key <Control>l
type 127.0.0.1:$port/
activate
wait
probe $H
mark site
sleep 1500
probe $H
key <Control>r
wait
probe $H
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
hl_check "R3 the app serves its socket" $?

o=$(cli +split --view=doc.md --name=doc 2>&1)
hl_check "R4 +split --view=doc.md opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK Live Zero" ]
hl_check "R5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

# The web processes under the app: bubblewrap runs them, so walk the tree.
webprocs() {
    local all p
    all="$APP"
    for _ in 1 2 3 4 5 6; do
        for p in $(ps -eo pid=,ppid= | awk -v set=" $all " 'index(set, " " $2 " ") { print $1 }'); do
            case " $all " in *" $p "*) ;; *) all="$all $p" ;; esac
        done
    done
    for p in $all; do
        case "$(cat /proc/$p/comm 2>/dev/null)" in WebKitWebProces*) echo "$p" ;; esac
    done
}

# ---- the driving script's half of the sync points ----------------------------
hl_wait_for 60 grep -q '^mark inplace' "$out"
md "Live One" "$fx/doc.md"
hl_wait_for 60 grep -q '^mark atomic' "$out"
md "Live Two" "$fx/doc.tmp" && mv -f "$fx/doc.tmp" "$fx/doc.md"
# A save that lands in two pieces further apart than the debounce (T3587):
# a slow writer, or any save on a loaded box. The short first piece renders
# on its own, and the document is too short to hold the scroll.
hl_wait_for 60 grep -q '^mark slow' "$out"
printf '# Live Half\n\nParagraph 1 of a document still being written.\n' > "$fx/doc.md"
sleep 0.8
md "Live Four" "$fx/doc.md"
hl_wait_for 60 grep -q '^mark rm' "$out"
rm -f "$fx/doc.md"
hl_wait_for 60 grep -q '^mark recreate' "$out"
md "Live Three" "$fx/doc.md"
hl_wait_for 60 grep -q '^mark cli-reload' "$out"
# The explicit reload: no save behind it, so its render is the one awaited.
reload_out=$(cli +reload --target=doc 2>&1); reload_rc=$?
hl_wait_for 60 grep -q '^mark kill' "$out"
victims=$(webprocs)
for p in $victims; do kill -KILL "$p" 2>/dev/null; done
hl_wait_for 60 grep -q '^mark page-save' "$out"
page "Page One"
hl_wait_for 60 grep -q '^mark css' "$out"
printf 'h1 { color: rgb(0, 128, 0); }\n' > "$fx/page/style.css"
hl_wait_for 60 grep -q '^mark page-reload' "$out"
page_reload_out=$(cli +reload --target=doc 2>&1); page_reload_rc=$?
hl_wait_for 60 grep -q '^mark site' "$out"
printf '<!DOCTYPE html><html><body><h1>Site One</h1></body></html>\n' > "$fx/site/index.html"
hl_wait_for 90 grep -q '^done' "$out"
hl_check "R6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
pr() { nth probe "$1"; }
st() { nth state "$1"; }
wt() { nth wait "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
scroll_of() { echo "${1##*|}"; }

[ "$(pr 1)" = "probe OK 600" ] && [ "$(pr 2)" = "probe OK 600" ]
hl_check "R7 the document scrolls, and the first render's scroll restore does not undo it (T3587)" $? "$(pr 1) / $(pr 2)"

p=$(pr 3)
has "$p" "probe OK Live One|" && [ "$(scroll_of "$p")" -ge 500 ] 2>/dev/null && [ "$(wt 1)" = "wait ok=true" ]
hl_check "R8 a save in place re-renders the file, keeping the scroll" $? "$(wt 1) / $p"

p=$(pr 4)
has "$p" "probe OK Live Two|" && [ "$(scroll_of "$p")" -ge 500 ] 2>/dev/null
hl_check "R9 an atomic save (temp file renamed over it) re-renders too, keeping the scroll" $? "$p"

p=$(pr 6)
has "$p" "probe OK Live Four|" && [ "$(scroll_of "$p")" -ge 500 ] 2>/dev/null && [ "$(pr 5)" = "probe OK 600" ] \
    && [ "$(wt 3)" = "wait ok=true" ] && [ "$(wt 4)" = "wait ok=true" ]
hl_check "R9b a save landing in two pieces (a short first render) still keeps the scroll (T3587)" $? "$(pr 5) / $(wt 3) / $(wt 4) / $p"

[ "$(pr 7)" = "probe OK true" ]
hl_check "R10 a deleted file shows the unreadable card, not a stale copy" $? "$(pr 7)"

[ "$(pr 8)" = "probe OK Live Three" ]
hl_check "R11 re-creating the file brings the document back" $? "$(pr 8)"

[ $reload_rc = 0 ] && [ "$(pr 9)" = "probe OK Live Three" ] && [ "$(wt 7)" = "wait ok=true" ]
hl_check "R12 +reload --target=<viewer> succeeds and re-renders" $? "rc=$reload_rc out=$reload_out / $(wt 7) / $(pr 9)"

[ -n "$victims" ] && [ "$(pr 10)" = "probe OK Live Three" ] && has "$(st 1)" "reloads=1 card=none"
hl_check "R13 a web process killed with SIGKILL is restarted and the file re-rendered" $? "victims=[$victims] $(pr 10) / $(st 1)"
grep -q 'viewer: web process terminated reason=0 -> reload' "$APP_LOG"
hl_check "R14 the kill reads as a crash (reason 0) and spends a restart" $? "$(grep -m3 'web process terminated' "$APP_LOG" | tr '\n' ' ')"

has "$(st 2)" "reloads=3 card=none"
hl_check "R15 WebKit's own termination reloads too, up to the cap (3 in a minute)" $? "$(st 2)"

p=$(pr 11)
has "$p" "probe OK This page keeps crashing|" && has "$p" "reloaded 3 times in a minute" && has "$(st 3)" "reloads=3 card=shown"
hl_check "R16 the 4th death inside the minute shows 'This page keeps crashing' instead of a blank pane" $? "$p / $(st 3)"
grep -q 'web process terminated reason=2 -> capped' "$APP_LOG"
hl_check "R17 the capped death is logged as capped, not reloaded" $? "$(grep 'web process terminated' "$APP_LOG" | tr '\n' ' ')"

[ "$(pr 12)" = "probe OK Live Three" ] && has "$(st 4)" "card=none"
hl_check "R18 Ctrl+R behind the crash card loads the page again" $? "$(pr 12) / $(st 4)"

p=$(pr 14)
has "$p" "probe OK Page One|" && [ "$(scroll_of "$p")" -ge 400 ] 2>/dev/null && [ "$(pr 13)" = "probe OK 500" ]
hl_check "R19 a saved .html page reloads in place, keeping the scroll" $? "$(pr 13) / $p"

[ "$(pr 15)" = "probe OK rgb(255, 0, 0)" ] && [ "$(pr 16)" = "probe OK rgb(255, 0, 0)" ]
hl_check "R20 editing a sibling stylesheet does not reload the page (only the viewed file is watched)" $? "$(pr 15) / $(pr 16)"

[ $page_reload_rc = 0 ] && [ "$(pr 17)" = "probe OK rgb(0, 128, 0)" ]
hl_check "R21 +reload picks the edited stylesheet up" $? "rc=$page_reload_rc out=$page_reload_out / $(pr 17)"

[ "$(pr 18)" = "probe OK Site Zero" ] && [ "$(pr 19)" = "probe OK Site Zero" ] && [ "$(pr 20)" = "probe OK Site One" ]
hl_check "R22 a website is not watched; Ctrl+R re-fetches it" $? "$(pr 18) / $(pr 19) / $(pr 20)"

# ---- +reload's refusals ------------------------------------------------------
o=$(cli +new-window --target=termwin 2>&1)
hl_check "R23 a terminal window opens for the refusal checks" $? "$o"
o=$(cli +split --target=termwin --name=tpane 2>&1)
hl_check "R24 a named terminal pane opens beside it" $? "$o"
sleep 1

o=$(cli +reload --target=tpane 2>&1); rc=$?
[ $rc != 0 ] && has "$o" "target 'tpane' is a terminal pane, nothing to reload"
hl_check "R25 +reload on a terminal pane refuses with win32's sentence" $? "rc=$rc $o"
o=$(cli +reload --target=termwin 2>&1); rc=$?
[ $rc != 0 ] && has "$o" "focused pane of 'termwin' is a terminal pane, nothing to reload"
hl_check "R26 +reload on a window focused on a terminal names the focused pane" $? "rc=$rc $o"
o=$(cli +reload --target=nosuch 2>&1); rc=$?
[ $rc != 0 ] && has "$o" "target 'nosuch' not found in registry"
hl_check "R27 +reload on a missing name says so" $? "rc=$rc $o"
o=$(cli +reload --config --target=doc 2>&1); rc=$?
[ $rc != 0 ] && has "$o" "--config cannot be combined with --target"
hl_check "R28 +reload --config --target is refused as two different requests" $? "rc=$rc $o"
o=$(cli +reload --config 2>&1); rc=$?
[ $rc = 0 ] && ! has "$o" "not served"
hl_check "R29 +reload --config reloads the app config (T3369; cli-reload.sh proves the effect)" $? "rc=$rc $o"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "R30 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -50
fi

hl_finish "$L"
