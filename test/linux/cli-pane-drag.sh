#!/usr/bin/env bash
# cli-pane-drag.sh - L11b (T3564) acceptance for pane rearrange mode and pane
# drops on the GTK debug app (docs/reference/pane-rearrange.md).
#
# Rearrange mode is toggled by its real key binding (Ctrl+Shift+. through the
# press-key seam), gives every pane a header that takes layout space (the
# terminal under it is laid out shorter), forces the tab bar visible, and is
# left with Escape through the window's own key handler. Drops go through
# SplitTree.dropPaneAt - the code a real release calls - by the debug-only
# `pane-drag` seam: the headless harness has no seat, so no pointer drag can
# START here (that half is NOT RUN; see the task). Every drop moves the very
# same panes: same shells, same pids.
#
# Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-pane-drag.sh
#
# NEGATIVE=1 presses the wrong chord (Ctrl+Shift+,) and must FAIL D2-D4.
# Output: one PASS/FAIL line per check, then 'CLI PANE DRAG: ALL PASS' or
# 'CLI PANE DRAG: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI PANE DRAG"
chord="ctrl+shift+period"
[ "${NEGATIVE:-0}" = 1 ] && chord="ctrl+shift+comma"

log=/tmp/cli-pane-drag-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "D0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "D0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
hl_check "D0c the app serves its socket" $?

# list_py <mode> <window> [arg]: shape (no ratios: H(a,V(b,c))), id/pid of a
# leaf by name.
list_py() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
mode, want = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
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
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    tab = next((t for t in w["tabs"] if t.get("selected")), w["tabs"][0])
    if mode == "shape": print(shape(tab["splits"]))
    for l in leaves(tab["splits"]):
        if mode == "id" and l.get("name") == arg: print(l["id"])
        if mode == "pid" and l.get("name") == arg: print(l.get("pid") or "")
' "$@" 2>/dev/null
}
shape_of() { list_py shape dw; }
shape_is() { [ "$(shape_of)" = "$1" ]; }
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

# pd <args...>: the pane-drag seam's reply.  pf <reply> <python expr over d>.
pd() { hl_ipc pane-drag "$@"; }
pf() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$2" 2>/dev/null; }
hdr() { # hdr <reply> <pane id> <field>
    pf "$1" "[h['$3'] for h in d['headers'] if h['pane'] == '$2'][0]"
}

# dw: a (unnamed, its name is its id), b right of it, c below b.
cli +new-window --target=dw > /dev/null 2>&1
hl_wait_for 15 has_window dw
a=$(shape_of)
cli +split --target=dw --name=b > /dev/null 2>&1
cli +split --pane=b --name=c --direction=down > /dev/null 2>&1
hl_wait_for 15 shape_is "H($a,V(b,c))"
hl_check "D1 window dw holds H(a,V(b,c))" $? "shape=$(shape_of)"
b=$(list_py id dw b); c=$(list_py id dw c)
pid_a=$(list_py pid dw "$a"); pid_b=$(list_py pid dw b); pid_c=$(list_py pid dw c)

r=$(pd --target="$a")
[ "$(pf "$r" "d['mode']")" = False ] && [ "$(hdr "$r" "$a" shown)" = False ]
hl_check "D1b the mode starts off: no header shown" $? "$r"
h_before=$(hdr "$r" "$a" content_height)

# --- the mode, by its key binding --------------------------------------------------

k=$(hl_ipc press-key --target="$a" --key="$chord")
mode_on() { [ "$(pf "$(pd --target="$a")" "d['mode']")" = True ]; }
hl_wait_for 5 mode_on
hl_check "D2 $chord turns rearrange mode on" $? "press=$k $(pd --target="$a")"

headers_up() {
    local r; r=$(pd --target="$a")
    for p in "$a" "$b" "$c"; do
        [ "$(hdr "$r" "$p" shown)" = True ] || return 1
        [ "$(hdr "$r" "$p" height)" -ge 20 ] 2>/dev/null || return 1
    done
}
hl_wait_for 5 headers_up
hl_check "D3 every pane shows a header at least 20px tall" $? "$(pd --target="$a")"
r=$(pd --target="$a")
h_on=$(hdr "$r" "$a" content_height)
hh=$(hdr "$r" "$a" height)
[ -n "$h_on" ] && [ -n "$h_before" ] && [ "$h_on" -le $((h_before - hh + 2)) ] && [ "$h_on" -ge 1 ]
hl_check "D4 the header takes layout space: a's terminal is laid out shorter by it" $? "before=$h_before on=$h_on header=$hh"
[ "$(pf "$r" "d['tabs_visible']")" = True ] && [ "$(pf "$r" "d['tabs_autohide']")" = False ]
hl_check "D5 the tab bar is forced visible (no autohide) with one tab" $? "$r"
[ -n "$(hdr "$r" "$b" title)" ]
hl_check "D5b a header names its pane" $? "$r"

# --- drops ------------------------------------------------------------------------

drop() { # drop <label> <want target> <want outcome> <want shape> <pd args...>
    local label=$1 want_t=$2 want_o=$3 want_s=$4; shift 4
    local r t o
    r=$(pd "$@")
    t=$(pf "$r" "d['drop']['target']"); o=$(pf "$r" "d['drop']['outcome']")
    hl_wait_for 5 shape_is "$want_s"
    [ "$t" = "$want_t" ] && [ "$o" = "$want_o" ] && shape_is "$want_s"
    hl_check "$label" $? "target=$t outcome=$o shape=$(shape_of) reply=$r"
}
drop "D6 a onto c's centre swaps them: H(c,V(b,a))" swap moved "H(c,V(b,a))" \
    --target="$a" --drop-on="$c" --fx=0.5 --fy=0.5
drop "D7 c onto b's lower triangle splits b downward: V(V(b,c),a)" split moved "V(V(b,c),a)" \
    --target="$c" --drop-on="$b" --fx=0.5 --fy=0.92
drop "D8 b onto c's upper triangle would leave it in place: nothing moves" split in_place "V(V(b,c),a)" \
    --target="$b" --drop-on="$c" --fx=0.5 --fy=0.08
drop "D9 a at the window's left edge spans that side: H(a,V(b,c))" top_level moved "H($a,V(b,c))" \
    --target="$a" --drop-on="$b" --fx=0.01 --fy=0.5
drop "D10 a on the b|c divider goes in that gap: V(b,V(a,c))" insert moved "V(b,V($a,c))" \
    --target="$a" --drop-on="$b" --fx=0.5 --fy=1.0
drop "D11 a onto itself is no target" none none "V(b,V($a,c))" \
    --target="$a" --drop-on="$a" --fx=0.5 --fy=0.5

[ "$(list_py pid dw "$a")" = "$pid_a" ] && [ "$(list_py pid dw b)" = "$pid_b" ] && [ "$(list_py pid dw c)" = "$pid_c" ] \
    && alive "$pid_a" && alive "$pid_b" && alive "$pid_c"
hl_check "D12 every drop MOVED the panes: same shells, still running" $? "a=$pid_a b=$pid_b c=$pid_c"
cli +send-keys --target="$a" 'echo D13_$((40+2))' Enter > /dev/null 2>&1
read_a() { cli +read --name="$a" --lines=20 2>/dev/null | grep -q 'D13_42'; }
hl_wait_for 10 read_a
hl_check "D13 the moved pane a still runs its shell" $?

# --- a pane that arrives in the mode, then Escape ---------------------------------------

cli +split --pane=b --name=d > /dev/null 2>&1
d_id() { [ -n "$(list_py id dw d)" ]; }
hl_wait_for 10 d_id
d=$(list_py id dw d)
d_up() { [ "$(hdr "$(pd --target="$a")" "$d" shown)" = True ]; }
hl_wait_for 5 d_up
hl_check "D14 a split made in the mode grows its header too" $? "$(pd --target="$a")"

r=$(pd --target="$a" --key=escape)
[ "$(pf "$r" "d['key_effect']")" = consumed ] && [ "$(pf "$r" "d['mode']")" = False ]
hl_check "D15 Escape leaves the mode" $? "$r"
headers_down() {
    local r; r=$(pd --target="$a")
    for p in "$a" "$b" "$c" "$d"; do [ "$(hdr "$r" "$p" shown)" = False ] || return 1; done
}
hl_wait_for 5 headers_down
hl_check "D16 every header is gone" $? "$(pd --target="$a")"
r=$(pd --target="$a" --key=escape)
[ "$(pf "$r" "d['key_effect']")" = passed ]
hl_check "D17 Escape with the mode off goes on to the pane" $? "$r"

hl_ipc press-key --target="$a" --key="$chord" > /dev/null
hl_wait_for 5 mode_on
k=$(hl_ipc press-key --target="$a" --key="$chord")
mode_off() { [ "$(pf "$(pd --target="$a")" "d['mode']")" = False ]; }
hl_wait_for 5 mode_off
hl_check "D18 the binding toggles the mode back off" $? "press=$k $(pd --target="$a")"

hl_finish "$L"
