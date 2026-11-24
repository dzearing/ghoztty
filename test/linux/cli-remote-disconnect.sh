#!/usr/bin/env bash
# cli-remote-disconnect.sh - L11a (T3563) acceptance for Close vs Disconnect on
# a remote window, against the GTK debug app and a loopback ghoztty-agent
# listening on TCP. An INTERACTIVE close (the pane keybind, a tab's x, the
# window's x) of anything riding a remote machine asks even when its shell is
# idle, and offers Disconnect (the default) beside Close and Cancel, naming the
# machine. Disconnect closes it here and leaves the remote shell running on the
# agent; Close ends it; Cancel keeps it. A local idle window still closes
# without asking, and `+close` never asks (Mac: the widening is deliberately
# not in closeSurface). Mac reference: docs/reference/remote-machines.md
# "Closing a remote window: Close vs Disconnect".
#
# The dialog is driven through the DEBUG-ONLY `close-dialog` seam: Wayland
# gives the headless harness no pointer to press a button with, so the seam
# starts the same close a keybind or an x does, reads the dialog up over the
# window and answers it. The oracle is the remote shell's pid: alive after a
# Disconnect (past the undo window, so the parked pane's end ran too), gone
# after a Close.
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-remote-disconnect.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop.
#
# NEGATIVE=1 answers Close where the script means Disconnect, so the remote
# shell dies and D4 must FAIL.
#
# Output: one PASS/FAIL line per check, then 'CLI REMOTE DISCONNECT: ALL PASS'
# or 'CLI REMOTE DISCONNECT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI REMOTE DISCONNECT"
disconnect=disconnect
[ "${NEGATIVE:-}" = 1 ] && disconnect=close

log=/tmp/cli-remote-disconnect-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "S2 a private headless Weston is up" $?
# DIAG: animations off (the harness's private config dir), to test whether
# an answered dialog only lingers because its close animation never ends.
[ "${ANIM:-off}" = off ] && { mkdir -p "$XDG_CONFIG_HOME/gtk-4.0"; printf '[Settings]
gtk-enable-animations=false
' > "$XDG_CONFIG_HOME/gtk-4.0/settings.ini"; }
app=$(hl_ghoztty) || hl_finish "$L"
agent_bin="$(dirname "$app")/ghoztty-agent"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
listening() { python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1",int(sys.argv[1])),1)' "$1" 2>/dev/null; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
dead() { ! alive "$1"; }

port=$(free_port)
hl_launch RAGENT "$agent_bin" --listen "127.0.0.1:$port" --headless
hl_wait_for 20 listening "$port"
hl_check "S3 a ghoztty-agent listens on 127.0.0.1:$port" $? "$(tail -5 "$RAGENT_LOG" 2>/dev/null | tr '\n' ' ')"

# Local panes are plain exec panes (no session persistence), so every
# agent-hosted pane in this run is the TCP agent's. A 1 s undo window, so a
# closed pane's parked end runs inside the script's waits.
export SHELL=/bin/sh
export GHOSTTY_ACCOUNT_STORE="$HL_RUNTIME/no-account.dat"
export GHOSTTY_ACCOUNT_KEYRING=off
unset GHOSTTY_RELAY_TOKEN
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --undo-timeout=1s --keybind=ctrl+shift+t=new_tab \
    -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
s4=$?
hl_check "S4 the app serves its socket" $s4
[ $s4 = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

# win <mode> <target> [arg]: one +list read about window <target>.
#   pid [name] - the shell pid of the leaf named [name] (else the first leaf)
#   lastpid    - the first leaf of the window's last tab
#   ntabs      - how many tabs
win() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
mode, want = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
d = json.load(sys.stdin)["data"]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    if mode == "ntabs": print(len(w["tabs"])); sys.exit(0)
    if mode == "lastpid": print(next(leaves(w["tabs"][-1]["splits"])).get("pid") or ""); sys.exit(0)
    for t in w["tabs"]:
        for l in leaves(t["splits"]):
            if mode == "pid" and (arg == "" or l.get("name") == arg): print(l.get("pid") or ""); sys.exit(0)
' "$@" 2>/dev/null
}
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }
no_window() { ! has_window "$1"; }
has_pane() { cli +list --json 2>/dev/null | grep -q "\"name\":\"$1\""; }
no_pane() { ! has_pane "$1"; }
pane_pid() { local p; p=$(win pid "$1" "${2:-}"); [ -n "$p" ] && [ "$p" != 0 ] && printf '%s' "$p"; }
ntabs_is() { [ "$(win ntabs "$1")" = "$2" ]; }

# dialog <target> [--op=...] [--answer=...]: the close-dialog seam's reply.
dialog() { local t=$1; shift; hl_ipc close-dialog "--target=$t" "$@" 2>&1; }
# field <json> <key>: one field of a seam reply.
field() { printf '%s' "$1" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else (str(v).lower() if isinstance(v,bool) else v))' "$2" 2>/dev/null; }

remote() { # remote <name>: open a remote window named <name>, print its shell pid
    cli +new-remote-window --host=127.0.0.1 --port="$port" --name="$1" > /dev/null 2>&1 || return 1
    hl_wait_for 15 pane_pid "$1" > /dev/null || return 1
    pane_pid "$1"
}

# --- a pane: the keybind's close of an IDLE remote split ------------------------
p0=$(remote rdp)
hl_check "D1 a remote window rdp opens on the TCP agent" $? "pid=$p0"
cli +split --target=rdp --name=rdp-a > /dev/null 2>&1
hl_wait_for 15 pane_pid rdp rdp-a > /dev/null
pa=$(pane_pid rdp rdp-a)
cli +split --target=rdp --name=rdp-b > /dev/null 2>&1
hl_wait_for 15 pane_pid rdp rdp-b > /dev/null
pb=$(pane_pid rdp rdp-b)
[ -n "$pa" ] && [ -n "$pb" ]
hl_check "D2 two remote splits rdp-a and rdp-b come up" $? "a=$pa b=$pb"

out=$(dialog rdp-a --op=pane)
[ "$(field "$out" open)" = true ] && [ "$(field "$out" disconnect)" = true ] &&
    field "$out" body | grep -q "This session runs on 127.0.0.1"
hl_check "D3 closing idle rdp-a asks, offers Disconnect, and names 127.0.0.1" $? "out=$out"

out=$(dialog rdp-a --answer=$disconnect)
hl_wait_for 10 no_pane rdp-a
gone=$?
sleep 3 # past the 1 s undo window: the parked pane's end has run
[ $gone = 0 ] && alive "$pa"
hl_check "D4 Disconnect removes rdp-a here and its remote shell keeps running" $? "out=$out gone=$gone pid=$pa"
echo "DIAG probe after D4: $(dialog rdp)"

out=$(dialog rdp-b --op=pane --answer=close)
hl_wait_for 10 no_pane rdp-b && hl_wait_for 10 dead "$pb"
hl_check "D5 Close removes rdp-b and ends its remote shell" $? "out=$out pid=$pb"

# --- a tab: the tab's x on a remote window's second tab -------------------------
out=$(hl_ipc press-key "--target=rdp" "--key=ctrl+shift+t" 2>&1)
hl_wait_for 10 ntabs_is rdp 2
hl_wait_for 15 win lastpid rdp > /dev/null
pt=$(win lastpid rdp)
[ -n "$pt" ] && ntabs_is rdp 2
hl_check "T1 a second (remote) tab opens in rdp" $? "out=$out pid=$pt tabs=$(win ntabs rdp)"

out=$(dialog rdp --op=tab)
[ "$(field "$out" open)" = true ] && [ "$(field "$out" disconnect)" = true ]
hl_check "T2 closing the idle remote tab asks and offers Disconnect" $? "out=$out"
out=$(dialog rdp --answer=$disconnect)
hl_wait_for 10 ntabs_is rdp 1
tabs=$?
sleep 3
[ $tabs = 0 ] && alive "$pt"
hl_check "T3 Disconnect closes the tab and its remote shell keeps running" $? "out=$out tabs=$(win ntabs rdp) pid=$pt"

# --- a window: the window's x --------------------------------------------------
# An answered dialog animates out; until it has, libadwaita spends the
# window's next close request on dismissing it (`+close --force` loops for the
# same reason). So the tab's dialog must be GONE before the window's x.
no_dialog() { [ "$(field "$(dialog "$1")" open)" = false ]; }
hl_wait_for 15 no_dialog rdp
w0=$?
hl_check "W0 the answered tab dialog has left the window" $w0 "$(dialog rdp)"
[ $w0 = 0 ] || { echo "--- tab/dialog log:"; grep -n -v "received action" "$APP_LOG" | grep -i "tab close\|answering\|window close\|gtk-\|adwaita\|critical\|warn\|undo" | tail -30; }
mark=$(wc -l < "$APP_LOG")
out=$(dialog rdp --op=window --answer=cancel)
[ "$(field "$out" disconnect)" = true ] && [ "$(field "$out" answered)" = cancel ] &&
    has_window rdp && alive "$p0"
w1=$?
hl_check "W1 Cancel on the window close keeps rdp and its shell" $w1 "out=$out pid=$p0"
[ $w1 = 0 ] || { echo "--- app log since the probe:"; tail -n +"$mark" "$APP_LOG" | head -40; }

out=$(dialog rdp --op=window)
[ "$(field "$out" open)" = true ] && [ "$(field "$out" disconnect)" = true ]
hl_check "W2 closing the idle remote window asks and offers Disconnect" $? "out=$out"
out=$(dialog rdp --answer=$disconnect)
hl_wait_for 10 no_window rdp
gone=$?
sleep 2
[ $gone = 0 ] && alive "$p0"
hl_check "W3 Disconnect closes window rdp and its remote shell keeps running" $? "out=$out gone=$gone pid=$p0"

pc=$(remote rdc)
out=$(dialog rdc --op=window --answer=close)
hl_wait_for 10 no_window rdc && hl_wait_for 10 dead "$pc"
hl_check "W4 Close on a remote window ends its remote shell" $? "out=$out pid=$pc"

# --- what does NOT ask --------------------------------------------------------
cli +new-window --name=loc > /dev/null 2>&1
hl_wait_for 15 pane_pid loc > /dev/null
out=$(dialog loc --op=window)
hl_wait_for 10 no_window loc
gone=$?
[ "$(field "$out" open)" = false ] && [ $gone = 0 ]
hl_check "X1 an idle LOCAL window closes without asking" $? "out=$out gone=$gone"

px=$(remote rdx)
out=$(cli +close --target=rdx 2>&1)
hl_wait_for 10 no_window rdx && hl_wait_for 10 dead "$px"
hl_check "X2 +close never asks: rdx closes and its remote shell ends" $? "out=$out pid=$px"

alive "$pa" && alive "$pt" && alive "$p0"
hl_check "X3 every disconnected remote shell is still running at the end" $? "a=$pa tab=$pt win=$p0"

hl_finish "$L"
