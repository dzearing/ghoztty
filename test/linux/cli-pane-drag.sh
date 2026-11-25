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
# T3615 adds the tab bar (D19-D31): a pane dropped on a tab's button becomes
# a new tab of its own at that index (Window.dropOnTabBar, the code a release
# on the AdwTabBar calls), a pane that is already its tab's only one moves
# its tab instead or stays put, a 500ms rest on another tab's button selects
# it (Window.tabDwellAt, the drag-motion handler's call), and a drop then
# lands in that tab's layout from the tab the pane left - which closes when
# it empties. A window's only pane never leaves it.
#
# Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-pane-drag.sh
#
# NEGATIVE=1 presses the wrong chord (Ctrl+Shift+,) and must FAIL D2-D5b, D14
# and D15 (7 failures): the drops do not depend on the mode.
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
# A real header (20px+) and the terminal at least that much shorter - so a
# run with no header at all (NEGATIVE=1) cannot pass on "0 shorter by 0".
[ -n "$h_on" ] && [ -n "$h_before" ] && [ "${hh:-0}" -ge 20 ] && [ "$h_on" -le $((h_before - hh)) ] && [ "$h_on" -ge 1 ]
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
drop "D6 a onto c's centre swaps them: H(c,V(b,a))" swap moved "H(c,V(b,$a))" \
    --target="$a" --drop-on="$c" --fx=0.5 --fy=0.5
drop "D7 c onto b's lower triangle splits b downward: V(V(b,c),a)" split moved "V(V(b,c),$a)" \
    --target="$c" --drop-on="$b" --fx=0.5 --fy=0.92
drop "D8 b onto c's upper triangle would leave it in place: nothing moves" split in_place "V(V(b,c),$a)" \
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

# --- the tab bar and the tab dwell (T3615) --------------------------------------------

# tabs_of <window>: every tab's shape in tab order, '*' before the selected
# one: "*a | V(b,c)".
tabs_of() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)["data"]
def shape(n):
    if n["type"] == "split":
        return "%s(%s,%s)" % (n["direction"][0].upper(), shape(n["left"]), shape(n["right"]))
    return n["terminal"].get("name", "")
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    print(" | ".join(("*" if t.get("selected") else "") + shape(t["splits"]) for t in w["tabs"]))
' "$1" 2>/dev/null
}
tabs_are() { [ "$(tabs_of dw)" = "$1" ]; }
pid_in() { # pid_in <window> <name>: the pid of a named pane in ANY tab
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
want, name = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)["data"]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    for t in w["tabs"]:
        for l in leaves(t["splits"]):
            if l.get("name") == name: print(l.get("pid") or "")
' "$1" "$2" 2>/dev/null
}
pid_d=$(list_py pid dw d)
# A known start: H(a,V(b,V(c,d))).
cli +rearrange --target=dw "--layout={\"direction\":\"horizontal\",\"left\":{\"pane\":\"$a\"},\"right\":{\"direction\":\"vertical\",\"left\":{\"pane\":\"b\"},\"right\":{\"direction\":\"vertical\",\"left\":{\"pane\":\"c\"},\"right\":{\"pane\":\"d\"}}}}" > /dev/null 2>&1
hl_wait_for 10 shape_is "H($a,V(b,V(c,d)))"
hl_check "D18b +rearrange sets the start: H(a,V(b,V(c,d)))" $? "shape=$(shape_of)"

hl_ipc press-key --target="$a" --key="$chord" > /dev/null
hl_wait_for 5 mode_on
bar_up() { [ "$(pf "$(pd --target="$a")" "d['tab_buttons']")" = 1 ]; }
hl_wait_for 5 bar_up
r=$(pd --target="$a")
[ "$(pf "$r" "d['tab_count']")" = 1 ] && [ "$(pf "$r" "d['tab_buttons']")" = 1 ]
hl_check "D19 in the mode the one-tab bar is on screen with one tab button to drop on" $? "$r"

tdrop() { # tdrop <label> <want outcome> <want tabs> <pd args...>
    local label=$1 want_o=$2 want_t=$3; shift 3
    local r o
    r=$(pd "$@")
    o=$(pf "$r" "d['drop']['outcome']")
    hl_wait_for 5 tabs_are "$want_t"
    [ "$(pf "$r" "d['drop']['target']")" = new_tab ] && [ "$o" = "$want_o" ] && tabs_are "$want_t"
    hl_check "$label" $? "outcome=$o tabs=$(tabs_of dw) reply=$r"
}
split_of() { hdr "$(pd --target="$a")" "$1" is_split; }  # split_of <pane id>

tdrop "D20 a dropped on the tab button becomes a new tab of its own, before it, selected" moved "*$a | V(b,V(c,d))" \
    --target="$a" --drop-tab=0
a_alone() { [ "$(split_of "$a")" = False ] && [ "$(split_of "$b")" = True ]; }
hl_wait_for 5 a_alone
hl_check "D20b the moved pane no longer reads as split; the tab it left still does" $? "a=$(split_of "$a") b=$(split_of "$b")"

r1=$(pd --target="$a" --drop-tab=0); r2=$(pd --target="$a" --drop-tab=1)
[ "$(pf "$r1" "d['drop']['outcome']")" = in_place ] && [ "$(pf "$r2" "d['drop']['outcome']")" = in_place ] \
    && tabs_are "*$a | V(b,V(c,d))"
hl_check "D21 a pane already a tab of its own, dropped either side of its tab, stays put" $? "r1=$r1 r2=$r2 tabs=$(tabs_of dw)"

tdrop "D22 d dropped on the second tab's button becomes a new tab there" moved "$a | *d | V(b,c)" \
    --target="$d" --drop-tab=1
tdrop "D23 a lone pane dropped past the next tab moves its tab there" moved "d | *$a | V(b,c)" \
    --target="$a" --drop-tab=2

r=$(pd --target="$a" --hover-tab=2)
[ "$(pf "$r" "d['dwell_tab']")" = 2 ] && [ "$(pf "$r" "d['selected_tab']")" = 1 ]
hl_check "D24 resting on another tab's button arms the dwell, and does not switch at once" $? "$r"
dwelt() { [ "$(pf "$(pd --target="$a")" "d['selected_tab']")" = 2 ]; }
hl_wait_for 5 dwelt
r=$(pd --target="$a")
[ "$(pf "$r" "d['selected_tab']")" = 2 ] && [ "$(pf "$r" "d['dwell_tab']")" = None ] && tabs_are "d | $a | *V(b,c)"
hl_check "D25 after the dwell that tab is on show, so the drag can go on into it" $? "$r tabs=$(tabs_of dw)"

r1=$(pd --target="$a" --hover-tab=2)
r2=$(pd --target="$a" --hover-tab=0); r3=$(pd --target="$a" --hover-leave)
sleep 1
r4=$(pd --target="$a")
[ "$(pf "$r1" "d['dwell_tab']")" = None ] && [ "$(pf "$r2" "d['dwell_tab']")" = 0 ] \
    && [ "$(pf "$r3" "d['dwell_tab']")" = None ] && [ "$(pf "$r4" "d['selected_tab']")" = 2 ]
hl_check "D26 the tab on show arms nothing, and leaving the bar stops the clock" $? "r1=$r1 r2=$r2 r3=$r3 r4=$r4"

drop_x() { # drop_x <label> <want target> <want tabs> <pd args...>
    local label=$1 want_t=$2 want_s=$3; shift 3
    local r t o
    r=$(pd "$@")
    t=$(pf "$r" "d['drop']['target']"); o=$(pf "$r" "d['drop']['outcome']")
    hl_wait_for 5 tabs_are "$want_s"
    [ "$t" = "$want_t" ] && [ "$o" = moved ] && tabs_are "$want_s"
    hl_check "$label" $? "target=$t outcome=$o tabs=$(tabs_of dw) reply=$r"
}
drop_x "D27 a from the tab it left splits c in the tab on show, and its old tab closes" split "d | *V(b,H(c,$a))" \
    --target="$a" --drop-on=c --fx=0.92 --fy=0.5
drop_x "D28 d from another tab swaps with b there: each takes the other's place" swap "b | *V(d,H(c,$a))" \
    --target="$d" --drop-on=b --fx=0.5 --fy=0.5
b_alone() { [ "$(split_of "$b")" = False ] && [ "$(split_of "$d")" = True ]; }
hl_wait_for 5 b_alone
hl_check "D28b after the swap b reads as alone and d as split" $? "b=$(split_of "$b") d=$(split_of "$d")"

[ "$(pid_in dw "$a")" = "$pid_a" ] && [ "$(pid_in dw b)" = "$pid_b" ] && [ "$(pid_in dw c)" = "$pid_c" ] \
    && [ "$(pid_in dw d)" = "$pid_d" ] && alive "$pid_a" && alive "$pid_b" && alive "$pid_c" && alive "$pid_d"
hl_check "D29 every tab-bar and cross-tab drop MOVED the panes: same shells, still running" $? \
    "a=$pid_a/$(pid_in dw "$a") b=$pid_b/$(pid_in dw b) c=$pid_c/$(pid_in dw c) d=$pid_d/$(pid_in dw d)"
cli +send-keys --target="$d" 'echo D30_$((40+3))' Enter > /dev/null 2>&1
read_d() { cli +read --name=d --lines=20 2>/dev/null | grep -q 'D30_43'; }
hl_wait_for 10 read_d
hl_check "D30 the pane that crossed tabs still runs its shell" $?

# A window's only pane, dropped on its own tab, is no move: a drag never
# closes a window.
cli +new-window --target=solo > /dev/null 2>&1
hl_wait_for 15 has_window solo
hl_ipc press-key --target=solo --key="$chord" > /dev/null
solo_bar() { [ "$(pf "$(pd --target=solo)" "d['tab_buttons']")" = 1 ]; }
hl_wait_for 5 solo_bar
r=$(pd --target=solo --drop-tab=0)
sleep 0.5
[ "$(pf "$r" "d['drop']['outcome']")" = in_place ] && has_window solo && [ "$(pf "$(pd --target=solo)" "d['tab_count']")" = 1 ]
hl_check "D31 a window's only pane dropped on its tab stays: the window keeps its one tab" $? "$r"

# Moving a live pane's widgets from one tab's tree into another's is where
# GTK complains (a widget with two parents, a destroyed child): none of it.
! grep -E -- '-(CRITICAL|WARNING) \*\*' "$APP_LOG" > /dev/null
hl_check "D32 the app logged no GTK critical or warning through the moves" $? "$(grep -E -m5 -- '-(CRITICAL|WARNING) \*\*' "$APP_LOG" | tr '\n' ' ')"

hl_finish "$L"
