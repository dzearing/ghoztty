#!/usr/bin/env bash
# cli-windows.sh - L7b (T3370) acceptance for +new-window, +split and +rename
# against the GTK debug app, over its pane-name registry: names target panes
# and windows, a named target that exists is kept rather than recreated, pane
# names belong to their window (T2250: the same name in two windows is
# ambiguous from outside both and resolves to the caller's own from inside
# one), and a window name is never a pane's. Driven by the CLI only. Run it
# ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-windows.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop.
#
# Output: one PASS/FAIL line per check, then 'CLI WINDOWS: ALL PASS' or
# 'CLI WINDOWS: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init

log=/tmp/cli-windows-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "W1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "CLI WINDOWS"

hl_start
hl_check "W2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "CLI WINDOWS"

# The CLI from OUTSIDE any pane (no caller window), and from inside a pane
# (the CLI forwards $GHOZTTY_PANE_ID as the caller, T2250).
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
cli_as() { local id=$1; shift; env -u GHOZTTY_IPC_SOCKET GHOZTTY_PANE_ID="$id" "$app" "$@"; }

# Every pane gets a plain interactive POSIX shell, so what a pane prints is
# predictable whatever the distro user's login shell is.
export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
hl_check "W3 the app serves its socket" $?

# summary: one line per window, 'target|title|leaf-name,leaf-name,...'
summary() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    leaves = [l for t in w["tabs"] for l in walk(t["splits"])]
    print("%s|%s|%s" % (w.get("target") or "", w.get("title") or "", ",".join(l.get("name", "") for l in leaves)))
' 2>/dev/null
}
# id_of <window-target> <pane-name>: the pane id of that name in that window.
id_of() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
want_w, want_p = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") != want_w: continue
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if want_p == "*" or l.get("name") == want_p:
                print(l["id"]); sys.exit(0)
' "$1" "$2" 2>/dev/null
}
windows() { summary | wc -l; }
leaves_in() { summary | awk -F'|' -v w="$1" '$1 == w { print $3 }' | tr ',' '\n' | grep -c .; }
read_has() { cli +read --name="$1" --lines=200 2>/dev/null | grep -Eq "$2"; }
# send_until <pane-id-or-name> <text> <regex>: type text + Enter into the pane
# until its screen matches. A new pane's shell may not be up when the first
# send lands (not started / still printing its banner), so this retries.
# $CALLER, when set, is the pane id the CLI says it runs from.
send_until() {
    local t=$1 txt=$2 re=$3 i j
    for i in $(seq 1 15); do
        if [ -n "${CALLER:-}" ]; then
            cli_as "$CALLER" +send-keys --target="$t" "$txt" Enter > /dev/null 2>&1
        else
            cli +send-keys --target="$t" "$txt" Enter > /dev/null 2>&1
        fi
        for j in 1 2 3 4 5 6; do
            read_has "${READ_AS:-$t}" "$re" && return 0
            sleep 0.25
        done
    done
    return 1
}

have_window() { [ "$(windows)" -ge 1 ]; }
hl_wait_for 20 have_window
first=$(summary | head -1 | cut -d'|' -f1)
[ -n "$first" ]
hl_check "W4 +list names the startup window (a minted window-N target)" $? "$(summary | tr '\n' ' ')"
echo "$first" | grep -Eq '^window-[0-9]+$'
hl_check "W4b the minted name has the window-N shape" $? "first=$first"

# +split --name from outside any pane: the front window, a new named pane.
out=$(cli +split --name=side 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -Eq "^created pane 'side' \([0-9a-f-]{36}\) in window '$first'$"
hl_check "W5 +split --name=side creates the pane and the reply names it and its window" $? "rc=$rc out=$out"
[ "$(leaves_in "$first")" = 2 ]
hl_check "W5b the window now has two panes" $? "$(summary | tr '\n' ' ')"

# The same request again is idempotent: no second pane.
out=$(cli +split --name=side 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q "pane 'side' already exists in this window ('$first'); reused it, no split created"
hl_check "W6 a second +split --name=side reuses it and creates nothing" $? "rc=$rc out=$out"
[ "$(leaves_in "$first")" = 2 ]
hl_check "W6b still two panes" $? "$(summary | tr '\n' ' ')"

# The name reaches the pane: the pane answers to it and carries it.
send_until side 'echo W7_$GHOZTTY_PANE_NAME' '^W7_side$'
hl_check "W7 +send-keys --target=side reaches it, and its \$GHOZTTY_PANE_NAME is side" $? "$(cli +read --name=side --lines=6 2>&1 | tr '\n' '|' | head -c 300)"

# +split options: --command runs in a shell that stays open, --env is baked,
# a bad direction and a bad percent are refused before anything opens.
cli +split --name=cmd --direction=down --env=W8VAR=baked "--command=echo W8_\$((40+2))" > /dev/null 2>&1
hl_wait_for 15 read_has cmd '^W8_42$'
hl_check "W8 +split --command runs its command in the new pane" $? "$(cli +read --name=cmd --lines=6 2>&1 | tr '\n' '|' | head -c 300)"
send_until cmd 'echo W8b_$W8VAR' '^W8b_baked$'
hl_check "W8b the pane outlives its command (still a shell) and has its --env" $? "$(cli +read --name=cmd --lines=6 2>&1 | tr '\n' '|' | head -c 300)"
out=$(cli +split --direction=sideways 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q 'invalid direction: sideways'
hl_check "W9 +split --direction=sideways is refused" $? "rc=$rc out=$out"
out=$(cli +split --percent=100 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q 'percent must be between 1 and 99, got 100'
hl_check "W9b +split --percent=100 is refused" $? "rc=$rc out=$out"
[ "$(leaves_in "$first")" = 3 ]
hl_check "W9c the refusals created nothing (three panes)" $? "$(summary | tr '\n' ' ')"

# +new-window --target: a named window, idempotent, and loud about what a
# re-run drops.
out=$(cli +new-window --target=work 2>&1); rc=$?
[ $rc = 0 ]
hl_check "W10 +new-window --target=work exits 0" $? "rc=$rc out=$out"
two_windows() { [ "$(windows)" = 2 ]; }
hl_wait_for 10 two_windows
summary | grep -q '^work|'
hl_check "W10b +list shows a second window with target work" $? "$(summary | tr '\n' ' ')"
out=$(cli +new-window --target=work --title=Ignored 2>&1); rc=$?
[ $rc = 0 ] && [ "$(windows)" = 2 ] && echo "$out" | grep -q "target 'work' already exists; kept it. Ignored: --title"
hl_check "W11 a second +new-window --target=work keeps it and names the dropped flag" $? "rc=$rc out=$out windows=$(windows)"

# Pane names belong to their window: 'side' in work is a new pane.
out=$(cli +split --target=work --name=side 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -Eq "^created pane 'side' \([0-9a-f-]{36}\) in window 'work'$"
hl_check "W12 +split --target=work --name=side creates work's own 'side'" $? "rc=$rc out=$out"
work_side=$(id_of work side)
first_side=$(id_of "$first" side)
[ -n "$work_side" ] && [ -n "$first_side" ] && [ "$work_side" != "$first_side" ]
hl_check "W12b two different panes are named side" $? "work=$work_side first=$first_side"

# From outside both windows the name is ambiguous, and the command fails.
out=$(cli +send-keys --target=side 'echo NEVER' 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "'side' names a pane in 2 windows ('$first', 'work'), so it is ambiguous here."
hl_check "W13 --target=side from outside both windows is ambiguous, naming them" $? "rc=$rc out=$out"

# From inside the work window it is work's own.
work_any=$(id_of work '*')
CALLER="$work_any" READ_AS="$work_side" send_until side 'echo W14_WORK' '^W14_WORK$'
r=$?
read_has "$first_side" '^W14_WORK$'; leaked=$?
[ $r = 0 ] && [ $leaked != 0 ]
hl_check "W14 --target=side from a pane in work reaches work's side only" $? "work=$r leaked_to_first=$([ $leaked = 0 ] && echo yes || echo no)"

# A pane name is never a window's, and a window name never a pane's.
out=$(cli +new-window --target=side 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "'side' is already the name of a pane, so no window can take it"
hl_check "W15 +new-window --target=side (a pane name) is refused" $? "rc=$rc out=$out"
out=$(cli +split --name=work 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "'work' is already the name of a window, so no pane can take it"
hl_check "W15b +split --name=work (a window name) is refused" $? "rc=$rc out=$out"
[ "$(windows)" = 2 ]
hl_check "W15c the refusals opened no window" $? "$(summary | tr '\n' ' ')"

# +new-window --name names the new window's pane, idempotently.
out=$(cli +new-window --name=solo 2>&1); rc=$?
three_windows() { [ "$(windows)" = 3 ]; }
hl_wait_for 10 three_windows
[ $rc = 0 ] && summary | grep -Eq '\|solo$'
hl_check "W16 +new-window --name=solo opens a window whose pane is solo" $? "rc=$rc $(summary | tr '\n' ' ')"
out=$(cli +new-window --name=solo 2>&1); rc=$?
[ $rc = 0 ] && [ "$(windows)" = 3 ]
hl_check "W16b a second +new-window --name=solo opens nothing" $? "rc=$rc windows=$(windows)"

# +rename pins a window title; an empty title clears the pin.
out=$(cli +rename --target=work --title=W17Title 2>&1); rc=$?
renamed() { summary | grep -q '^work|W17Title|'; }
hl_wait_for 5 renamed
[ $rc = 0 ]
hl_check "W17 +rename --target=work --title=W17Title sets the window's title" $? "rc=$rc $(summary | tr '\n' ' ')"
out=$(cli +rename --target=work --title= 2>&1); rc=$?
cleared() { ! summary | grep -q '^work|W17Title|'; }
hl_wait_for 5 cleared
[ $rc = 0 ]
hl_check "W17b +rename --title= clears the pin" $? "rc=$rc $(summary | tr '\n' ' ')"
out=$(cli +rename --target=nosuch --title=x 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "target 'nosuch' not found in registry"
hl_check "W17c +rename of a name nothing holds fails, naming it" $? "rc=$rc out=$out"
out=$(cli +rename --title=x 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q -- '--target is required for +rename'
hl_check "W17d +rename without --target is refused" $? "rc=$rc out=$out"

# --view is a viewer pane, which the Linux app does not have yet: it says so
# rather than open a terminal.
out=$(cli +split --view=/etc/hostname 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q 'not served by the Linux app yet (T3338)'
hl_check "W18 +split --view says viewers are not served yet (T3338)" $? "rc=$rc out=$out"

# Nothing above crashed the app.
kill -0 "$APP" 2>/dev/null
hl_check "W19 the app is still running" $?
! grep -Eq 'panic|reached unreachable' "$APP_LOG"
hl_check "W19b no panic in the app's log" $? "$(grep -Em3 'panic|unreachable' "$APP_LOG" | tr '\n' ' ')"

hl_finish "CLI WINDOWS"
