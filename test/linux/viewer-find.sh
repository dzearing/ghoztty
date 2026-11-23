#!/usr/bin/env bash
# viewer-find.sh - L9e (T3414) acceptance: find in page in a GTK viewer pane.
# Ctrl+F opens the card with the caret in its field; typing highlights every
# match and shows a live n/m count; Enter / Shift+Enter, the chevrons, Ctrl+G
# and F3 (with their Shift twins) step, wrapping; an emptied field drops the
# count; Escape closes the card, clears the highlights and KEEPS the query, so
# Ctrl+G resumes it and Ctrl+F comes back to it selected; the count follows a
# file saved under an open search; the same find works in a code pane and on
# a WEBSITE (the script is injected into every document, not only the
# template), which also says "frames not searched" for a laid-out iframe; past
# 5000 matches the count reads 1/5000+; a picture declines the chords and
# closes an open card. Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-find.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh). Weston headless has
# no seat and Wayland no input injection, so the card and the keys are driven
# by the debug build's GHOZTTY_TEST_VIEWER_STEPS seam (src/apprt/gtk/Viewer.zig):
# the pane's own key handler, the find field's text (its `changed` runs the
# search, as typing does) and the buttons' own `clicked`. The highlights are
# read back from the page (CSS.highlights) - there are no pixels here.
#
# Output: one PASS/FAIL line per check, then 'VIEWER FIND: ALL PASS' or
# 'VIEWER FIND: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER FIND"

log=/tmp/viewer-find-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "F1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixtures --------------------------------------------------------------
fx="$HL_RUNTIME/fx"
mkdir -p "$fx/site"
# Three needles in three blocks, plus a near miss that must not count.
printf '# Find One\n\nthe first needle here\n\nneedles and a needle\n\nneedlx is not one\n' > "$fx/doc.md"
printf 'const needle = 1;\n// another needle\n' > "$fx/code.zig"
printf 'e %.0s' $(seq 6000) > "$fx/many.md"
printf '\x89PNG\r\n\x1a\n' > "$fx/pic.png"
cat > "$fx/site/index.html" <<'HTML'
<!DOCTYPE html><html><body>
<h1>Site needle</h1>
<p>needle one</p><p>needle two</p><div>last needle</div>
<iframe srcdoc="<p>needle inside the frame</p>" style="width:240px;height:60px"></iframe>
</body></html>
HTML
port=$((20000 + $$ % 20000))
(cd "$fx/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) > "$HL_RUNTIME/http.log" 2>&1 &
HTTP_PID=$!
HL_PIDS="$HL_PIDS $HTTP_PID"
hl_wait_for 10 sh -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"
# How many ranges each highlight paints, read off the page itself.
HL="(function(){if(!window.CSS||!CSS.highlights)return 'nohl';var a=CSS.highlights.get('ghoztty-find'),c=CSS.highlights.get('ghoztty-find-current');return (a?a.size:0)+'/'+(c?c.size:0)})()"

# ---- the steps the pane runs once it has rendered --------------------------
steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
state
key <Control>g
key <Control>f
state
find needle
sleep 700
state
probe $HL
key Return
sleep 400
state
key <Shift>Return
sleep 400
state
key <Control>g
sleep 400
state
key F3
sleep 400
state
key F3
sleep 400
state
key <Shift>F3
sleep 400
state
click find-next
sleep 400
state
click find-previous
sleep 400
state
find needlez
sleep 600
state
find
sleep 400
state
find needle
sleep 600
key Escape
sleep 300
state
probe $HL
key <Control>g
sleep 600
state
key Escape
key <Control>f
sleep 600
state
mark edit
sleep 3000
state
key <Control>l
type $fx/code.zig
activate
wait
sleep 900
state
key <Control>l
type 127.0.0.1:$port/
activate
wait
sleep 1200
state
probe $HL
key <Control>f
find e
key <Control>l
type $fx/many.md
activate
wait
sleep 1500
state
key <Control>l
type $fx/pic.png
activate
wait
sleep 600
state
key <Control>f
key <Control>g
key F3
state
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
hl_check "F3 the app serves its socket" $?

o=$(cli +split --view=doc.md --name=doc 2>&1)
hl_check "F4 +split --view=doc.md opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK Find One" ]
hl_check "F5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

# The driving script's half of the sync point: a fourth needle lands in the
# file under the open search, and the pane's live reload re-renders it.
hl_wait_for 90 grep -q '^mark edit' "$out"
printf '\none more needle\n' >> "$fx/doc.md"
hl_wait_for 120 grep -q '^done' "$out"
hl_check "F6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
st() { nth state "$1"; }
pr() { nth probe "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
k=$(grep '^key' "$out")
kn() { echo "$k" | sed -n "${1}p"; }

s=$(st 1)
has "$s" "find=closed" && has "$s" "count=-" && [ "$(kn 1)" = "key <Control>g handled=false" ]
hl_check "F7 the card starts closed, and Ctrl+G with no search yet is declined" $? "$s / $(kn 1)"

s=$(st 2)
[ "$(kn 2)" = "key <Control>f handled=true" ] && has "$s" "focus=find" && has "$s" "find=open"
hl_check "F8 Ctrl+F opens the card with the caret in its field" $? "$(kn 2) / $s"

s=$(st 3)
has "$s" "findq=needle" && has "$s" "count=1/3 "
hl_check "F9 typing searches: the count reads 1/3 (a near miss does not count)" $? "$s"

# find.js paints the current match in its own highlight and the rest in the
# other, so three matches read 2 + 1.
[ "$(pr 1)" = "probe OK 2/1" ]
hl_check "F10 every match is painted, and exactly one is the current one" $? "$(pr 1)"

has "$(st 4)" "count=2/3 " && has "$(st 5)" "count=1/3 "
hl_check "F11 Enter steps forward, Shift+Enter back" $? "$(st 4) / $(st 5)"

has "$(st 6)" "count=2/3 " && has "$(st 7)" "count=3/3 " && has "$(st 8)" "count=1/3 " && has "$(st 9)" "count=3/3 "
hl_check "F12 Ctrl+G and F3 step forward and wrap past the last match; Shift+F3 wraps back" $? "$(st 6) / $(st 7) / $(st 8) / $(st 9)"

has "$(st 10)" "count=1/3 " && has "$(st 11)" "count=3/3 "
hl_check "F13 the card's chevrons step too" $? "$(st 10) / $(st 11)"

has "$(st 12)" "count=No results"
hl_check "F14 a query with no matches says No results, not 0/0" $? "$(st 12)"

s=$(st 13)
has "$s" "findq= " && has "$s" "count=-"
hl_check "F15 an emptied field takes the count with it" $? "$s"

s=$(st 14)
has "$s" "find=closed" && has "$s" "findq=needle" && has "$s" "focus=content" && [ "$(pr 2)" = "probe OK 0/0" ]
hl_check "F16 Escape closes the card, clears the highlights, keeps the query, hands focus to the page" $? "$s / $(pr 2)"

s=$(st 15)
echo "$k" | grep -q '^key <Control>g handled=true' && has "$s" "find=open" && has "$s" "count=2/3 "
hl_check "F17 Ctrl+G after Escape reopens the card and resumes the search" $? "$s"

s=$(st 16)
has "$s" "find=open" && has "$s" "findsel=0-6" && has "$s" "focus=find"
hl_check "F18 Ctrl+F comes back to the kept query with all of it selected" $? "$s"

s=$(st 17)
has "$s" "/4 "
hl_check "F19 the count stays live: a needle saved into the file under the open search is counted" $? "$s"

s=$(st 18)
has "$s" "mode=code" && has "$s" "find=open" && has "$s" "count=1/2 "
hl_check "F20 the open search follows a navigation into a code pane" $? "$s"

s=$(st 19)
has "$s" "mode=web" && has "$s" "count=1/4 " && has "$s" "note=frames not searched"
hl_check "F21 find works on a website (4 needles in the page, the frame's not counted) and says frames are not searched" $? "$s"
[ "$(pr 3)" = "probe OK 3/1" ]
hl_check "F22 the website's matches are painted by the injected script" $? "$(pr 3)"

s=$(st 20)
has "$s" "count=1/5000+ "
hl_check "F23 past 5000 matches the count reads 1/5000+, never an exact-looking number" $? "$s"

s=$(st 21)
has "$s" "mode=image" && has "$s" "find=closed" && has "$s" "count=-"
hl_check "F24 navigating to a picture closes the open card, count and all" $? "$s"
echo "$k" | tail -3 | grep -q 'handled=true'
[ $? != 0 ] && echo "$k" | tail -3 | grep -c 'handled=false' | grep -q '^3$' && has "$(st 22)" "find=closed"
hl_check "F25 a picture declines Ctrl+F, Ctrl+G and F3" $? "$(echo "$k" | tail -3 | tr '\n' ' ') / $(st 22)"

grep -q 'viewer: find state=count query=needle total=3 index=1' "$APP_LOG" &&
    grep -q 'viewer: find state=closed query=needle' "$APP_LOG"
hl_check "F26 the app log records the search and the close" $? "$(grep -m3 'viewer: find' "$APP_LOG" | tr '\n' ' ')"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "F27 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -40
fi

hl_finish "$L"
