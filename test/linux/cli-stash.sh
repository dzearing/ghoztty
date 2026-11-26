#!/usr/bin/env bash
# cli-stash.sh - L8d-2 (T3596) acceptance for +stash / +restore against the
# GTK debug app. +stash takes a pane out of its window's LAYOUT and leaves it
# in the TREE: its shell keeps running, every verb still reaches it, +list
# reports it `stashed: true`, its split collapses into the sibling and the
# pane sidebar keeps a (dimmed) row for it. +restore puts it back in the slot
# it left; focus moves only with --focus. Both are idempotent, a window always
# shows one pane, and the refusals are Mac's sentences (win32 T1827). Also the
# Ctrl+Shift+M stash chord, a sidebar click on a stashed row, and a close that
# leaves only stashed panes. T3667: a keyboard resize, equalize and swap_split
# act on the panes on show (a collapsed split keeps its ratio, a stashed pane
# is never a swap partner), and an Alt-click on a stashed row swaps it with
# the focused pane. (The relaunch keeping a stash is session-restore.sh's RS
# checks; a pane drop's stash-aware judgement is a none-lane unit test in
# gtk/pane_drop_apply.zig.) Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-stash.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop.
#
# NEGATIVE=1 presses Ctrl+Shift+N for the stash chord, which must FAIL K1.
#
# Output: one PASS/FAIL line per check, then 'CLI STASH: ALL PASS' or
# 'CLI STASH: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI STASH"
chord=ctrl+shift+m
[ "${NEGATIVE:-0}" = 1 ] && { chord=ctrl+shift+n; echo "  NEGATIVE CONTROL: the stash chord is the wrong one - this run MUST fail"; }

log=/tmp/cli-stash-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "S2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --keybind=ctrl+alt+shift+l=resize_split:right,40 --keybind=ctrl+alt+shift+e=equalize_splits \
    --keybind=ctrl+alt+shift+h=swap_split:left \
    -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
f3=$?
hl_check "S3 the app serves its socket" $f3
[ $f3 = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

# lst <mode> <window> [arg]: read +list once.
#   shape   - the active tab's tree as H50(a,V50(b,c)), a leaf by its name
#   stashed - the names of the stashed leaves, space separated, tree order
#   focused - the focused leaf's name
#   id/pid  - the id / shell pid of the leaf named [arg]
lst() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
mode, want = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
d = json.load(sys.stdin)["data"]
def shape(n):
    if n["type"] == "split":
        return "%s%d(%s,%s)" % (n["direction"][0].upper(), round(n["ratio"] * 100),
                                shape(n["left"]), shape(n["right"]))
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
    if mode == "stashed": print(" ".join(l.get("name", "") for l in leaves(tab["splits"]) if l.get("stashed")))
    for l in leaves(tab["splits"]):
        if mode == "focused" and l.get("focused"): print(l.get("name", ""))
        if mode == "id" and l.get("name") == arg: print(l["id"])
        if mode == "pid" and l.get("name") == arg: print(l.get("pid") or "")
' "$@" 2>/dev/null
}
shape_is() { [ "$(lst shape "$1")" = "$2" ]; }
stashed_is() { [ "$(lst stashed "$1")" = "$2" ]; }
focused_is() { [ "$(lst focused "$1")" = "$2" ]; }
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
# on_stage <window> <pane>: the names on the stage of <pane>'s tab (the panes
# laid out), sorted; "single" when the tab shows one pane.
on_stage() {
    local pane; pane=$(lst id "$1" "$2")
    hl_ipc pane-stack "--target=$pane" 2>/dev/null | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
st = d.get("stage")
names = dict(x.split("=", 1) for x in sys.argv[1:])
if st is None: print("single"); sys.exit(0)
print(" ".join(sorted(names.get(p["pane"], p["pane"]) for p in st.get("panes", []))))
' "$ida=a" "$idb=b" "$idc=c" 2>/dev/null
}
stage_is() { [ "$(on_stage "$1" "$2")" = "$3" ]; }
dump() { echo "shape=$(lst shape sw) stashed=[$(lst stashed sw)] focused=$(lst focused sw) stage=[$(on_stage sw a)]"; }

# sw: a | b over c, every pane named.
cli +new-window --target=sw --name=a > /dev/null 2>&1
hl_wait_for 15 has_window sw
cli +split --target=sw --name=b > /dev/null 2>&1
cli +split --pane=b --name=c --direction=down > /dev/null 2>&1
hl_wait_for 15 shape_is sw "H50(a,V50(b,c))"
hl_check "S4 window sw holds a | b over c" $? "$(lst shape sw)"
ida=$(lst id sw a); idb=$(lst id sw b); idc=$(lst id sw c)
pid_b=$(lst pid sw b)
hl_wait_for 10 stage_is sw a "a b c"
hl_check "S5 all three panes are on the stage, nothing stashed, a focused" \
    $([ "$(lst stashed sw)" = "" ] && focused_is sw a && stage_is sw a "a b c"; echo $?) "$(dump)"

# --- refusals ---------------------------------------------------------------
refused() { # refused <label> <expect-substring> <verb> <args...>
    local label=$1 want=$2; shift 2
    local out rc
    out=$(cli "$@" 2>&1); rc=$?
    [ $rc != 0 ] && printf '%s' "$out" | grep -qF -- "$want" && stashed_is sw ""
    hl_check "$label" $? "rc=$rc out=$out $(dump)"
}
refused "E1 +stash without --target is refused" "--target is required for +stash" +stash
refused "E2 +restore without --target is refused" "--target is required for +restore" +restore
refused "E3 a pane nothing holds is not found" "target 'nobody' not found in registry" +stash --target=nobody
refused "E4 a window is not a pane" "target 'sw' is a window; +stash takes a pane (a name or pane id)" +stash --target=sw

# --- stash b: out of the layout, still in the tree ---------------------------
out=$(cli +stash --target=b 2>&1); rc=$?
hl_check "T1 +stash --target=b succeeds" $rc "$out"
hl_wait_for 10 stashed_is sw "b"
hl_check "T2 +list reports b stashed:true and only b" $? "$(dump)"
shape_is sw "H50(a,V50(b,c))"
hl_check "T3 b is still a leaf of the tree, in its slot" $? "$(dump)"
hl_wait_for 10 stage_is sw a "a c"
hl_check "T4 the stage lays out a and c only (b's split collapsed into c)" $? "$(dump)"
alive "$pid_b"
hl_check "T5 b's shell is still running" $? "pid=$pid_b"
focused_is sw a
hl_check "T6 the focus stayed on a (b did not hold it)" $? "$(dump)"
cli +send-keys --target=b 'echo stash-marker-$((6*7))' Enter > /dev/null 2>&1
b_says() { cli +read --name=b 2>/dev/null | grep -q 'stash-marker-42'; }
hl_wait_for 10 b_says
hl_check "T7 a stashed pane still takes +send-keys and answers +read" $? "$(cli +read --name=b 2>&1 | tail -3)"
out=$(cli +stash --target=b 2>&1); rc=$?
[ $rc = 0 ] && stashed_is sw "b" && stage_is sw a "a c"
hl_check "T8 stashing it again succeeds and changes nothing (idempotent)" $? "rc=$rc out=$out $(dump)"

# --- the sidebar keeps a row for it ------------------------------------------
sb() { hl_ipc pane-sidebar "--target=$1" ${2:+"--click=$2"} 2>/dev/null; }
field() {
    sb "$1" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
s = d.get("sidebar") or {}
r = s.get("rows") or []
print(eval(sys.argv[1]))
' "$2" 2>/dev/null
}
if [ "$(field "$ida" 's["all_windows"]')" = True ]; then sb "$ida" scope > /dev/null; fi
row_stashed() { field "$ida" "[(x['pane'], x.get('stashed')) for x in r if x['kind'] == 'terminal']"; }
want_rows="[('$ida', False), ('$idc', False), ('$idb', True)]"
row_is() { [ "$(row_stashed)" = "$1" ]; }
hl_wait_for 10 row_is "$want_rows"
hl_check "T9 the sidebar lists a and c, then b in the tray, marked stashed (T3698)" $? "$(row_stashed)"

# --- the last pane on screen cannot go ---------------------------------------
out=$(cli +stash --target=c 2>&1); rc=$?
hl_wait_for 10 stashed_is sw "b c"
s=$?
[ $rc = 0 ] && [ $s = 0 ] && stage_is sw a single
hl_check "T10 stashing c too leaves a alone on screen" $? "rc=$rc out=$out $(dump)"
refused_last() {
    local out rc
    out=$(cli +stash --target=a 2>&1); rc=$?
    [ $rc != 0 ] && printf '%s' "$out" | grep -qF "target 'a' is the last pane on screen in its window; a window always shows at least one pane" \
        && stashed_is sw "b c"
    hl_check "T11 stashing the last pane on screen is refused" $? "rc=$rc out=$out $(dump)"
}
refused_last

# --- restore ------------------------------------------------------------------
out=$(cli +restore --target=c 2>&1); rc=$?
hl_wait_for 10 stashed_is sw "b"
s=$?
[ $rc = 0 ] && [ $s = 0 ] && stage_is sw a "a c" && focused_is sw a
hl_check "R1 +restore c brings it back, and without --focus the focus stays on a" $? "rc=$rc out=$out $(dump)"
out=$(cli +restore --target=b --focus 2>&1); rc=$?
hl_wait_for 10 stashed_is sw ""
s=$?
hl_wait_for 10 focused_is sw b
[ $rc = 0 ] && [ $s = 0 ] && focused_is sw b && shape_is sw "H50(a,V50(b,c))" && stage_is sw a "a b c"
hl_check "R2 +restore b --focus brings it back to its own slot and focuses it" $? "rc=$rc out=$out $(dump)"
out=$(cli +restore --target=b 2>&1); rc=$?
[ $rc = 0 ] && stashed_is sw "" && stage_is sw a "a b c"
hl_check "R3 restoring a pane on screen succeeds and changes nothing" $? "rc=$rc out=$out $(dump)"

# --- stashing the focused pane hands focus to a pane on screen ----------------
out=$(cli +stash --target=b 2>&1); rc=$?
hl_wait_for 10 stashed_is sw "b"
focus_moved() { f=$(lst focused sw); [ "$f" = a ] || [ "$f" = c ]; }
hl_wait_for 10 focus_moved
hl_check "F1 stashing the focused pane moves the focus to a pane on screen" $? "rc=$rc $(dump)"

# --- a sidebar click on a stashed row restores and focuses it ----------------
sb "$ida" "$idb" > /dev/null
hl_wait_for 10 stashed_is sw ""
s=$?
hl_wait_for 10 focused_is sw b
[ $s = 0 ] && focused_is sw b
hl_check "C1 clicking b's stashed row restores it and focuses it" $? "$(dump)"

# --- the stash chord ----------------------------------------------------------
cli +close --target=c > /dev/null 2>&1   # a | b
hl_wait_for 10 shape_is sw "H50(a,b)"
hl_check "K0 closing c leaves a | b" $? "$(dump)"
hl_ipc press-key "--target=$idb" "--key=$chord" > /dev/null 2>&1
hl_wait_for 10 stashed_is sw "b"
hl_check "K1 $chord on b stashes it" $? "$(dump)"

# --- closing the last pane on screen brings the top of the stash back --------
# a on screen, b stashed (K1). Split a new pane d off a and stash it on top.
cli +split --pane=a --name=d > /dev/null 2>&1
has_d() { [ -n "$(lst id sw d)" ]; }
hl_wait_for 10 has_d
cli +stash --target=d > /dev/null 2>&1
hl_wait_for 10 stashed_is sw "d b"
s=$?
cli +close --target=a > /dev/null 2>&1
gone_a() { [ -z "$(lst id sw a)" ]; }
hl_wait_for 10 gone_a
hl_wait_for 10 stashed_is sw "b"
[ $s = 0 ] && stashed_is sw "b" && has_window sw && focused_is sw d
hl_check "X1 closing the only pane on screen brings back the top of the stash (d), focused" $? "$(dump)"

# --- spatial verbs over what is on show (T3667) -------------------------------
# sv: p | q | r as H50(p,H50(q,r)), then q stashed - on show: p | r, the
# inner split collapsed into r. Every verb below must act on p | r and leave
# the collapsed split (q's slot) as it was.
cli +new-window --target=sv --name=p > /dev/null 2>&1
hl_wait_for 15 has_window sv
cli +split --target=sv --name=q > /dev/null 2>&1
cli +split --pane=q --name=r > /dev/null 2>&1
hl_wait_for 15 shape_is sv "H50(p,H50(q,r))"
hl_check "V0 window sv holds p | q | r" $? "$(lst shape sv)"
idp=$(lst id sv p); idq=$(lst id sv q); idr=$(lst id sv r)
cli +stash --target=q > /dev/null 2>&1
hl_wait_for 10 stashed_is sv "q"
hl_check "V1 q is stashed: p | r on show" $? "$(lst shape sv) stashed=[$(lst stashed sv)]"
sb "$idp" "$idr" > /dev/null
hl_wait_for 10 focused_is sv r
hl_check "V2 a click on r's row focuses r" $? "focused=$(lst focused sv)"
# A resize from r: the divider on show is p|r (the root). The collapsed q|r
# split is r's NEAREST horizontal split, and moving it would change nothing
# anyone sees.
root_grew() { lst shape sv | grep -qE '^H(5[1-9]|[6-9][0-9])\(p,H50\(q,r\)\)$'; }
hl_ipc press-key "--target=$idr" "--key=ctrl+alt+shift+l" > /dev/null 2>&1
hl_wait_for 10 root_grew
hl_check "V3 a keyboard resize moves the divider on show (p|r), not q's collapsed split" $? "$(lst shape sv)"
# Equalize: p | r even out to 50; a stashed q claims no share (an equalize of
# all three would put the root at 33), and its own split keeps its 50.
hl_ipc press-key "--target=$idr" "--key=ctrl+alt+shift+e" > /dev/null 2>&1
hl_wait_for 10 shape_is sv "H50(p,H50(q,r))"
hl_check "V4 equalize evens out p | r only (root back to 50, not 33)" $? "$(lst shape sv)"
# Swap left from r: its neighbour on show is p, not the stashed q.
hl_ipc press-key "--target=$idr" "--key=ctrl+alt+shift+h" > /dev/null 2>&1
hl_wait_for 10 shape_is sv "H50(r,H50(q,p))"
s=$?
[ $s = 0 ] && stashed_is sv "q" && focused_is sv r
hl_check "V5 swap_split swaps r with p on show; q stays stashed in its slot, r keeps focus" $? "$(lst shape sv) stashed=[$(lst stashed sv)] focused=$(lst focused sv)"
# Alt-click q's stashed row: q takes the focused r's slot, r takes q's place
# in the stash.
sb "$idp" "alt:$idq" > /dev/null
hl_wait_for 10 shape_is sv "H50(q,H50(r,p))"
s=$?
hl_wait_for 10 focused_is sv q
[ $s = 0 ] && stashed_is sv "r" && focused_is sv q
hl_check "A1 an Alt-click on q's stashed row swaps it with the focused r: q on show, focused, r stashed" $? "$(lst shape sv) stashed=[$(lst stashed sv)] focused=$(lst focused sv)"
sb "$idp" "alt:$idp" > /dev/null
hl_wait_for 10 focused_is sv p
stashed_is sv "r" && focused_is sv p && shape_is sv "H50(q,H50(r,p))"
hl_check "A2 an Alt-click on a row on show is a plain click (focus, no swap)" $? "$(lst shape sv) stashed=[$(lst stashed sv)] focused=$(lst focused sv)"

grep -q "IPC: stashed 'b'" "$APP_LOG" && grep -q "IPC: restored 'c'" "$APP_LOG"
hl_check "L1 the app logs each stash and restore" $? "$(grep -c 'IPC: ' "$APP_LOG")"

hl_finish "$L"
