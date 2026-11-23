#!/usr/bin/env bash
# url-scheme.sh - L14 (T3343) acceptance for a ghoztty:// link handed to the
# GTK app from OUTSIDE it, both ways a Linux desktop delivers one:
#
#   E  the desktop entry's `Exec=ghoztty ... %u` line: `ghoztty <url>` is an
#      activation process, not a terminal - it forwards a focus over the IPC
#      socket, says what went wrong, and exits 0 focused / 1 nothing has that
#      name / 2 not a link this build understands (win32's codes).
#   D  D-Bus `org.freedesktop.Application.Open` (the entry is DBusActivatable),
#      which GLib hands to GApplication::open in the running app.
#
# Both are focus-only: nothing is ever created, on a miss or otherwise. Run it
# ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\url-scheme.sh
#
# Everything runs inside the private headless Weston and a private session
# bus, so nothing reaches WSLg, the user's desktop or the user's bus.
#
# Output: one PASS/FAIL line per check, then 'URL SCHEME: ALL PASS' or
# 'URL SCHEME: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="URL SCHEME"

log=/tmp/url-scheme-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "F1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
app_id=com.dzearing.ghoztty-debug
obj=/com/dzearing/ghoztty_debug

# A private session bus, so the app can own its D-Bus name (single-instance)
# without ever meeting the user's bus.
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/test-bus"
hl_launch BUS dbus-daemon --session --nofork --nopidfile --address="$DBUS_SESSION_BUS_ADDRESS"
hl_wait_for 10 test -S "$XDG_RUNTIME_DIR/test-bus"
hl_check "F3 a private session bus is up" $?

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
# link <url>: what the Exec line runs. Quiet: a miss is logged, not shown.
link() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID GHOZTTY_URL_SCHEME_QUIET=1 timeout 20 "$app" --gtk-single-instance=true "$@"; }

dialogs="$HL_RUNTIME/dialogs.txt"
: > "$dialogs"
export SHELL=/bin/sh
export GHOZTTY_TEST_URL_SCHEME_DIALOG="$dialogs"
hl_launch APP "$app" --gtk-single-instance=true
hl_wait_for 30 test -S "$sock"
hl_check "F4 the app serves its socket" $?

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
    print("%s|%s|%s" % (w.get("target") or "", int(bool(w.get("focused"))),
        ",".join("%s:%d:%s" % (l.get("name", ""), int(bool(l.get("focused"))), l["id"]) for l in leaves)))
' 2>/dev/null
}
windows() { summary | wc -l; }
leaves_in() { summary | awk -F'|' -v w="$1" '$1 == w { print $3 }' | tr ',' '\n' | grep -c .; }
leaves_are() { [ "$(leaves_in "$1")" = "$2" ]; }
# pane_focused <window> <pane-name-or-id>
pane_focused() { summary | awk -F'|' -v w="$1" '$1 == w { print $3 }' | tr ',' '\n' | grep -Eq "(^$2:1:|:1:$2\$)"; }
pane_id() { summary | awk -F'|' -v w="$1" '$1 == w { print $3 }' | tr ',' '\n' | awk -F: -v n="$2" '$1 == n { print $3 }'; }
dump() { summary | tr '\n' ' '; }
shown() { grep -c '^shown ' "$dialogs"; }

have_window() { [ "$(windows)" -ge 1 ]; }
hl_wait_for 20 have_window
hl_check "F5 the app opened its first window" $? "$(dump)"

cli +new-window --target=wa > /dev/null 2>&1
cli +split --target=wa --name=fa > /dev/null 2>&1
hl_wait_for 10 leaves_are wa 2
hl_check "F6 window wa holds two panes (its first and fa)" $? "$(dump)"
sleep 1
wa_main=$(summary | awk -F'|' '$1 == "wa" { print $3 }' | tr ',' '\n' | awk -F: '$1 != "fa" { print $3; exit }')
pane_focused wa "$wa_main"
hl_check "F7 wa's first pane holds the focus" $? "$(dump)"
n0=$(windows)

# --- E: the Exec line --------------------------------------------------------

out=$(link "ghoztty-debug://focus/fa" 2>&1); rc=$?
hl_wait_for 10 pane_focused wa fa
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ]
hl_check "E1 'ghoztty ghoztty-debug://focus/fa' exits 0 and focuses pane fa" $? "rc=$rc out=$out $(dump)"

out=$(link "ghoztty://focus/$wa_main" 2>&1); rc=$?
hl_wait_for 10 pane_focused wa "$wa_main"
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ]
hl_check "E2 the release spelling ghoztty://focus/<pane id> works in a debug build too" $? "rc=$rc out=$out $(dump)"

out=$(link "ghoztty-debug://focus/feat%2Ffa" 2>&1); rc=$?
[ $rc = 1 ] && [ "$(windows)" = "$n0" ]
hl_check "E3 a link to a name nothing holds exits 1 and opens nothing" $? "rc=$rc out=$out $(dump)"
echo "$out" | grep -q "Can't focus \"feat/fa\""
hl_check "E4 ...and says which name it could not focus (percent-decoded)" $? "out=$out"

out=$(link "ghoztty-debug://open/fa" 2>&1); rc=$?
[ $rc = 2 ] && [ "$(windows)" = "$n0" ] && echo "$out" | grep -q "Unsupported Ghoztty link"
hl_check "E5 an unknown verb exits 2, says unsupported, and does nothing" $? "rc=$rc out=$out"

out=$(GHOZTTY_IPC_SOCKET="$XDG_RUNTIME_DIR/nobody-here.sock" GHOZTTY_URL_SCHEME_QUIET=1 timeout 20 "$app" "ghoztty-debug://focus/fa" 2>&1); rc=$?
[ $rc = 1 ] && [ "$(windows)" = "$n0" ]
hl_check "E6 a cold click (no instance answers) exits 1 and launches nothing" $? "rc=$rc out=$out $(dump)"

# The dialog path, standalone: the activation process brings up GTK on the
# harness's Weston for one AdwAlertDialog (the debug seam closes it).
: > "$dialogs"
out=$(env -u GHOZTTY_IPC_SOCKET timeout 30 "$app" "ghoztty-debug://focus/nothing-here" 2>&1); rc=$?
[ $rc = 1 ] && grep -q "^shown Can't focus \"nothing-here\"|No open Ghoztty window or pane has that name" "$dialogs"
hl_check "E7 a miss shows the shared 'Can't focus' dialog, then exits 1" $? "rc=$rc dialogs=$(cat "$dialogs") out=$(echo "$out" | grep -E 'seam|dialog|CRITICAL|WARNING|adw' | tail -6)"

# A burst of clicks is one dialog: each Exec click is its own process.
: > "$dialogs"
env -u GHOZTTY_IPC_SOCKET timeout 30 "$app" "ghoztty-debug://focus/burst-a" > /dev/null 2>&1 & b1=$!
env -u GHOZTTY_IPC_SOCKET timeout 30 "$app" "ghoztty-debug://focus/burst-b" > /dev/null 2>&1 & b2=$!
env -u GHOZTTY_IPC_SOCKET timeout 30 "$app" "ghoztty-debug://focus/burst-c" > /dev/null 2>&1 & b3=$!
wait $b1; r1=$?; wait $b2; r2=$?; wait $b3; r3=$?
[ "$(shown)" = 1 ] && [ $r1 = 1 ] && [ $r2 = 1 ] && [ $r3 = 1 ]
hl_check "E8 three simultaneous misses show ONE dialog and all exit 1" $? "shown=$(shown) rc=$r1,$r2,$r3"

# (`ghoztty -e cmd ghoztty://...` is a launch, not an activation: that rule is
# url_activation.zig's unit tests; running one here would only open a terminal.)

# --- D: D-Bus Open -----------------------------------------------------------

dbus_open() {
    gdbus call --session --dest "$app_id" --object-path "$obj" \
        --method org.freedesktop.Application.Open "['$1']" "{}" 2>&1
}

out=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner "$app_id" 2>&1)
echo "$out" | grep -q true
hl_check "D0 the app owns $app_id on the private bus" $? "out=$out"

out=$(dbus_open "ghoztty-debug://focus/fa"); rc=$?
hl_wait_for 10 pane_focused wa fa
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ]
hl_check "D1 D-Bus Open of ghoztty-debug://focus/fa focuses pane fa" $? "rc=$rc out=$out $(dump)"

out=$(dbus_open "ghoztty://focus/$wa_main"); rc=$?
hl_wait_for 10 pane_focused wa "$wa_main"
hl_check "D2 D-Bus Open of the release spelling by pane id focuses it" $? "rc=$rc out=$out $(dump)"

: > "$dialogs"
out=$(dbus_open "ghoztty-debug://focus/gone-window"); rc=$?
hl_wait_for 10 test -s "$dialogs"
grep -q "^shown Can't focus \"gone-window\"|" "$dialogs" && [ "$(windows)" = "$n0" ]
hl_check "D3 D-Bus Open of a missing name shows the dialog in the app and opens nothing" $? "rc=$rc dialogs=$(cat "$dialogs") $(dump)"

: > "$dialogs"
out=$(dbus_open "ghoztty-debug:focus/fa"); rc=$?
hl_wait_for 10 test -s "$dialogs"
grep -q "^shown Unsupported Ghoztty link|ghoztty-debug:focus/fa isn't a link" "$dialogs"
hl_check "D4 a malformed ghoztty link says unsupported" $? "dialogs=$(cat "$dialogs") app=$(grep -E "gtk_url_scheme|seam" "$APP_LOG" | tail -6 | tr '\n' ' ')"

: > "$dialogs"
out=$(dbus_open "https://example.com/"); rc=$?
sleep 2
[ "$(shown)" = 0 ] && [ "$(windows)" = "$n0" ]
hl_check "D5 a URI that is not ours is ignored silently" $? "rc=$rc shown=$(shown) $(dump)"

grep -q "panic\|reached unreachable" "$APP_LOG"
[ $? != 0 ]
hl_check "G1 the app logged no panic" $? "$(grep -m3 'panic\|unreachable' "$APP_LOG")"
kill -0 "$APP" 2>/dev/null
hl_check "G2 the app is still running" $?

hl_finish "$L"
