#!/usr/bin/env bash
# pane-pop-out.sh - L11b3 (T3618) acceptance for moving a pane into a new
# window of its own on the GTK debug app: a pane drag let go over nothing,
# and the rearrange header's pop-out button (Mac PaneHeaderView /
# TerminalController.newWindow(at:), win32 pane_relocate.popOutAllowed).
#
# The headless harness has no seat, so no pointer drag can START here (that
# half is NOT RUN; the task says so). What it drives instead is the very call
# a drag's no-target cancel makes (`pane-drag --release-nowhere`, the
# header's `releaseOverNothing`) and the button itself, by its own clicked
# signal (`pane-drag --pop-out`, which, like GTK, gives a disabled button no
# click).
#
#   P1-P1c  build, harness, the app's socket
#   P2      a window H(a,V(b,c)) in rearrange mode: every header's pop-out on
#   P3-P5   a window's LAST pane: its button is disabled, a click does
#           nothing, a release over nothing is refused - no window opens,
#           none closes
#   P6-P8   c released over nothing: a new window holding only c (mode on,
#           as the drag was made in it), the same shell still running, and
#           its window left H(a,b)
#   P9      c is now its window's last pane: its button is disabled
#   P10     b moved into a tab of its own: a, alone in ITS tab, may pop out
#           now that the window has two tabs
#   P11-P12 b's button moves it out: a new window, same shell; its old window
#           keeps a in one tab, and a's button is disabled again
#   P13     no GTK critical or warning
#
# Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\pane-pop-out.sh
#
# NEGATIVE=1 aims both moves (P6 and P11) at the lone window's last pane
# instead, and must FAIL exactly P6, P7, P9, P11 and P12 (5 failures): a
# refused move opens no window. P8 still passes - c never moved, so its shell
# is untouched.
# Output: one PASS/FAIL line per check, then 'PANE POP OUT: ALL PASS' or
# 'PANE POP OUT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PANE POP OUT"

log=/tmp/pane-pop-out-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "P1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "P1b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
hl_check "P1c the app serves its socket" $?

# list_py <mode> <arg>: read +list --json.
#   shape <target>   the selected tab's shape of that window, names as leaves
#   id <name>        the pane id of the pane named <name>
#   where <id>       "<window#> <tabs> <panes in its tab> <pid>" for pane <id>
#   windows          how many windows the app has
list_py() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
mode, arg = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
d = json.load(sys.stdin)["data"]
def shape(n):
    if n["type"] == "split":
        return "%s(%s,%s)" % (n["direction"][0].upper(), shape(n["left"]), shape(n["right"]))
    return n["terminal"].get("name", "")
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
if mode == "windows": print(len(d["windows"]))
for wi, w in enumerate(d["windows"]):
    if mode == "shape" and (w.get("target") or "") == arg:
        tab = next((t for t in w["tabs"] if t.get("selected")), w["tabs"][0])
        print(shape(tab["splits"]))
    for t in w["tabs"]:
        ls = list(leaves(t["splits"]))
        for l in ls:
            if mode == "id" and l.get("name") == arg: print(l["id"])
            if mode == "where" and l["id"] == arg:
                print(wi, len(w["tabs"]), len(ls), l.get("pid") or "")
' "$@" 2>/dev/null
}
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
field() { echo "$1" | cut -d' ' -f"$2"; }

pd() { hl_ipc pane-drag "$@"; }
pf() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$2" 2>/dev/null; }
hdr() { # hdr <reply> <pane id> <field>
    pf "$1" "[h['$3'] for h in d['headers'] if h['pane'] == '$2'][0]"
}
mode_on() { [ "$(pf "$(pd --target="$1")" "d['mode']")" = True ]; }

# --- the windows -------------------------------------------------------------------

cli +new-window --target=pw --name=a > /dev/null 2>&1
hl_wait_for 15 has_window pw
cli +split --target=pw --name=b > /dev/null 2>&1
cli +split --pane=b --name=c --direction=down > /dev/null 2>&1
shape_is() { [ "$(list_py shape pw)" = "$1" ]; }
hl_wait_for 15 shape_is "H(a,V(b,c))"
a=$(list_py id a); b=$(list_py id b); c=$(list_py id c)
pid_b=$(field "$(list_py where "$b")" 4); pid_c=$(field "$(list_py where "$c")" 4)

cli +new-window --target=lw --name=lone > /dev/null 2>&1
hl_wait_for 15 has_window lw
l=$(list_py id lone)

hl_ipc press-key --target="$a" --key=ctrl+shift+period > /dev/null
hl_ipc press-key --target="$l" --key=ctrl+shift+period > /dev/null
hl_wait_for 5 mode_on "$a"
hl_wait_for 5 mode_on "$l"
pops_on() {
    local r; r=$(pd --target="$a")
    for p in "$a" "$b" "$c"; do [ "$(hdr "$r" "$p" pop_out)" = True ] || return 1; done
}
hl_wait_for 5 pops_on
hl_check "P2 pw is H(a,V(b,c)) in rearrange mode, every header's pop-out enabled" $? "shape=$(list_py shape pw) $(pd --target="$a")"

# --- a window's last pane may not pop out ---------------------------------------------

r=$(pd --target="$l")
[ "$(pf "$r" "d['mode']")" = True ] && [ "$(hdr "$r" "$l" shown)" = True ] && [ "$(hdr "$r" "$l" pop_out)" = False ]
hl_check "P3 the lone window's only pane shows a header whose pop-out is disabled" $? "$r"
w0=$(list_py windows)
r=$(pd --target="$l" --pop-out)
[ "$(pf "$r" "d['drop']['outcome']")" = none ] && [ "$(list_py windows)" = "$w0" ] && has_window lw
hl_check "P4 clicking the disabled button does nothing: still $w0 windows" $? "$r"
r=$(pd --target="$l" --release-nowhere)
[ "$(pf "$r" "d['drop']['outcome']")" = refused ] && [ "$(list_py windows)" = "$w0" ] && has_window lw \
    && [ "$(field "$(list_py where "$l")" 3)" = 1 ]
hl_check "P5 releasing it over nothing is refused: no window opens, none closes" $? "$r"

# --- a release over nothing ------------------------------------------------------------

mover=$c
[ "${NEGATIVE:-0}" = 1 ] && mover=$l
r=$(pd --target="$mover" --release-nowhere)
wc=$(field "$(list_py where "$c")" 1); wa=$(field "$(list_py where "$a")" 1)
[ "$(pf "$r" "d['drop']['target']")" = new_window ] && [ "$(pf "$r" "d['drop']['outcome']")" = moved ] \
    && [ "$(list_py windows)" = $((w0 + 1)) ] && [ "$wc" != "$wa" ] \
    && [ "$(pf "$r" "d['tab_count']")" = 1 ] && [ "$(pf "$r" "[h['pane'] for h in d['headers']]")" = "['$c']" ]
hl_check "P6 c released over nothing opens a new window holding only c" $? "$r where_c=$(list_py where "$c") where_a=$(list_py where "$a")"
shape_ab() { [ "$(list_py shape pw)" = "H(a,b)" ]; }
hl_wait_for 5 shape_ab && [ "$(pf "$r" "d['mode']")" = True ] && [ "$(hdr "$r" "$c" shown)" = True ]
hl_check "P7 pw is left H(a,b), and the new window is in rearrange mode with c's header" $? "shape=$(list_py shape pw) $r"
[ "$(field "$(list_py where "$c")" 4)" = "$pid_c" ] && alive "$pid_c"
cli +send-keys --target="$c" 'echo P8_$((40+2))' Enter > /dev/null 2>&1
read_c() { cli +read --name="$c" --lines=20 2>/dev/null | grep -q 'P8_42'; }
hl_wait_for 10 read_c
hl_check "P8 it is the same pane: same shell ($pid_c), still running" $? "where=$(list_py where "$c")"
r=$(pd --target="$c")
[ "$(hdr "$r" "$c" pop_out)" = False ]
hl_check "P9 c is its new window's last pane: its pop-out is disabled" $? "$r"

# --- a lone pane in a window of two tabs; the button -----------------------------------

r=$(pd --target="$b" --drop-tab=0)
twotabs() { [ "$(field "$(list_py where "$a")" 2)" = 2 ]; }
hl_wait_for 5 twotabs
r=$(pd --target="$a")
[ "$(pf "$r" "d['tab_count']")" = 2 ] && [ "$(hdr "$r" "$a" pop_out)" = True ] && [ "$(hdr "$r" "$b" pop_out)" = True ]
hl_check "P10 with b in a tab of its own, a - alone in its tab - may pop out (the window has two)" $? "$r"

mover=$b
[ "${NEGATIVE:-0}" = 1 ] && mover=$l
w1=$(list_py windows)
r=$(pd --target="$mover" --pop-out)
wb=$(field "$(list_py where "$b")" 1); wa=$(field "$(list_py where "$a")" 1)
[ "$(pf "$r" "d['drop']['outcome']")" = moved ] && [ "$(list_py windows)" = $((w1 + 1)) ] && [ "$wb" != "$wa" ] \
    && [ "$(field "$(list_py where "$b")" 4)" = "$pid_b" ] && alive "$pid_b"
hl_check "P11 b's pop-out button moves it into a new window: same shell ($pid_b)" $? "$r where_b=$(list_py where "$b")"
r=$(pd --target="$a")
[ "$(field "$(list_py where "$a")" 2)" = 1 ] && [ "$(hdr "$r" "$a" pop_out)" = False ] && [ "$wb" != "$wa" ]
hl_check "P12 pw keeps a in one tab, and a's pop-out is disabled again" $? "$r where_a=$(list_py where "$a")"

[ -s "$APP_LOG" ] && ! grep -E -- '-(CRITICAL|WARNING) \*\*' "$APP_LOG" > /dev/null
hl_check "P13 the app logged no GTK critical or warning" $? "$(grep -E -m5 -- '-(CRITICAL|WARNING) \*\*' "$APP_LOG" | tr '\n' ' ')"

hl_finish "$L"
