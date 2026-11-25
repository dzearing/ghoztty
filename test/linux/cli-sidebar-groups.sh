#!/usr/bin/env bash
# cli-sidebar-groups.sh - L10e (T3608) acceptance for editing groups from the
# GTK pane sidebar's all-windows list (docs/reference/pane-sidebar.md "All
# windows"):
#
#   - a window row's right-click menu: Create Group..., Move to Group (the
#     other groups, only when there is one) and Remove from Group (grouped
#     windows only);
#   - Move to Group retitles the window `<group>: <its name>` and it lists
#     under that group; Remove from Group puts its own name back;
#   - Create Group... opens an empty in-place field (placeholder "Group
#     name") where the row's name was; Return makes the window `<typed>:
#     <name>`, Escape or nothing typed changes nothing, and a name that could
#     not head a group (a `: ` of its own) changes nothing;
#   - the field keeps what was typed across a redraw;
#   - the Ungrouped header's pencil (first of its buttons) opens the same
#     field, and Return names every lone window as that group.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-sidebar-groups.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop. The harness has no pointer: the debug
# build's `pane-sidebar` IPC seam (IpcHandlers.zig) pops a row's menu
# (`--menu`), picks from it (`--menu-pick`), types into the field (`--edit`)
# and presses Return or Escape in it (`--edit-key`), through the live
# widgets' own code.
#
# NEGATIVE=1 never presses Return after typing the new group's name, which
# must FAIL G9.
#
# Output: one PASS/FAIL line per check, then 'CLI SIDEBAR GROUPS: ALL PASS' or
# 'CLI SIDEBAR GROUPS: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI SIDEBAR GROUPS"

log=/tmp/cli-sidebar-groups-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "G0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "G0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/sidebar-groups-fixture"
mkdir -p "$fixture/proj"
export SHELL=/bin/sh
export HOME="$fixture"

rm -f "$sock"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --macos-pane-sidebar=expanded \
    --working-directory="$fixture/proj" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
g0c=$?
hl_check "G0c the app serves its socket" $g0c
[ $g0c = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

# sb <target> [seam args...]: the seam's report for that target's window.
sb() { local t=$1; shift; hl_ipc pane-sidebar "--target=$t" "$@" 2>/dev/null; }
# field <target> <python expr over s (the sidebar), r (its rows), row(id),
# head(label[, kind]), heads(kind), m (the menu or {}) and e (the field or
# {})> [seam args...]
field() {
    local t=$1 e=$2; shift 2
    sb "$t" "$@" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
s = d.get("sidebar") or {}
r = s.get("rows") or []
m = s.get("menu") or {}
e = s.get("editing") or {}
def row(i):
    return next((x for x in r if x["pane"] == i), {})
def head(label, kind="window"):
    return next((x for x in r if x["label"] == label and x["kind"] == kind), {})
def heads(kind):
    return [x["label"] for x in r if x["kind"] == kind]
def under(label):
    # The project header a window row is listed under (None: ungrouped).
    p = None
    for x in r:
        if x["kind"] == "project": p = x["label"]
        elif x["kind"] == "ungrouped": p = None
        elif x["kind"] == "window" and x["label"] == label: return p
    return "missing"
print(eval(sys.argv[1]))
' "$e" 2>/dev/null
}
is() { [ "$(field "$1" "$2")" = "$3" ]; }
# isa <target> <expr> <want> [seam args...]: is, after those seam args.
isa() { local t=$1 x=$2 w=$3; shift 3; [ "$(field "$t" "$x" "$@")" = "$w" ]; }
# lst <python expr over W (windows by target) and T (every window's title)>
lst() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
W = {(w.get("target") or ""): w for w in d["windows"]}
T = [w.get("title") or "" for w in d["windows"]]
print(eval(sys.argv[1]))
' "$1" 2>/dev/null
}
lst_is() { [ "$(lst "$1")" = "$2" ]; }

# ---- 0. three windows: two lone, one grouped ---------------------------------
cli +new-window --target=wa --title=wa > /dev/null 2>&1
cli +new-window --target=wb --title=wb > /dev/null 2>&1
cli +new-window --target=p1 --title="grp: one" > /dev/null 2>&1
hl_wait_for 15 lst_is 'all(t in W for t in ("wa", "wb", "p1"))' True
[ "$(field wa 's["all_windows"]')" = True ] || sb wa --click=scope > /dev/null
hl_wait_for 10 is wa '(s["all_windows"], under("wb"), under("one"))' "(True, None, 'grp')"
hl_check "G1 all windows lists wb ungrouped and 'grp: one' under grp" $? "$(sb wa)"
kb=$(field wa 'head("wb")["pane"]')
k1=$(field wa 'head("one")["pane"]')

# ---- 1. the menu ---------------------------------------------------------------
isa wa '(m.get("row"), m.get("items"), m.get("groups"))' "('$kb', ['Create Group…', 'Move to Group'], ['grp'])" "--menu=$kb"
hl_check "G2 a lone window's menu: Create Group..., Move to Group with the one group, no Remove" $? "$(sb wa)"
isa wa '(m.get("items"), m.get("groups"))' "(['Create Group…', 'Remove from Group'], [])" "--menu=$k1"
hl_check "G3 a grouped window's: no Move (its own group is the only one), and Remove from Group" $? "$(sb wa)"
grep -q 'pane sidebar window menu open title=grp: one groups=0 remove=true' "$APP_LOG"
hl_check "G3b the live menu was popped (logged)" $? "$(grep -a 'window menu' "$APP_LOG" | tail -3 | tr '\n' ' ')"

# ---- 2. Move to Group, Remove from Group -------------------------------------
sb wa "--menu=$kb" --menu-pick=move:grp > /dev/null
hl_wait_for 10 lst_is '"grp: wb" in T' True
hl_check "G4 Move to Group retitles the window <group>: <its name>" $? "$(lst 'T')"
hl_wait_for 10 is wa 'under("wb")' grp
hl_check "G5 and it lists under that group" $? "$(sb wa)"
isa wa 'm.get("items")' "['Create Group…', 'Remove from Group']" "--menu=$kb"
hl_check "G6 its menu now offers Remove from Group" $? "$(sb wa)"
sb wa --menu-pick=remove > /dev/null
hl_wait_for 10 lst_is '("wb" in T, "grp: wb" in T)' "(True, False)"
hl_check "G7 Remove from Group puts its own name back" $? "$(lst 'T')"
hl_wait_for 10 is wa 'under("wb")' None
hl_check "G7b back among the ungrouped windows" $? "$(sb wa)"

# ---- 3. Create Group... and its field -----------------------------------------
sb wa "--menu=$kb" --menu-pick=create > /dev/null
is wa '(e.get("row"), e.get("purpose"), e.get("placeholder"), e.get("text"), e.get("shown"))' "('$kb', 'create_group', 'Group name', '', True)"
hl_check "G8 Create Group... opens an empty field with the placeholder, in the row" $? "$(sb wa)"
hl_wait_for 5 is wa 'e.get("focused")' True
hl_check "G8b the field takes the caret" $? "$(sb wa)"
sb wa --edit=newg > /dev/null
hl_wait_for 10 is wa '(e.get("text"), e.get("shown"))' "('newg', True)"
hl_check "G8c it keeps what was typed across a redraw" $? "$(sb wa)"
[ "${NEGATIVE:-0}" = 1 ] || sb wa --edit-key=enter > /dev/null
hl_wait_for 10 lst_is '"newg: wb" in T' True
hl_check "G9 Return makes the window <typed>: <its name>" $? "$(lst 'T')"
hl_wait_for 10 is wa '(under("wb"), e == {})' "('newg', True)"
hl_check "G9b under the new group, and the field is gone" $? "$(sb wa)"
[ "${NEGATIVE:-0}" = 1 ] && sb wa --edit-key=escape > /dev/null

ka=$(field wa 'head("wa")["pane"]')
sb wa "--menu=$ka" --menu-pick=create > /dev/null
sb wa --edit=zzz > /dev/null
sb wa --edit-key=escape > /dev/null
hl_wait_for 10 is wa 'e == {}' True
lst_is '"wa" in T' True
hl_check "G10 Escape closes the field and changes nothing" $? "$(lst 'T') $(sb wa)"
sb wa "--menu=$ka" --menu-pick=create > /dev/null
sb wa --edit-key=enter > /dev/null
hl_wait_for 10 is wa 'e == {}' True
lst_is '"wa" in T' True
hl_check "G11 Return with nothing typed changes nothing" $? "$(lst 'T')"
sb wa "--menu=$ka" --menu-pick=create > /dev/null
sb wa "--edit=a: b" --edit-key=enter > /dev/null
hl_wait_for 10 is wa 'e == {}' True
lst_is '"wa" in T' True
hl_check "G12 a name with a ': ' of its own cannot head a group: nothing changes" $? "$(lst 'T')"
grep -q 'pane sidebar window group unchanged: not a group name' "$APP_LOG"
hl_check "G12b and the refusal is logged" $?

# ---- 4. the Ungrouped header's pencil ------------------------------------------
hl_wait_for 10 is wa 'row("ungrouped").get("tools")' "['rename', 'add', 'close']"
hl_check "G13 the Ungrouped header offers the pencil first, then + and x" $? "$(sb wa)"
lone=$(field wa 'sorted(x["label"] for x in r if x["kind"] == "window" and under(x["label"]) is None)')
sb wa --click=tool:rename:ungrouped > /dev/null
is wa '(e.get("row"), e.get("purpose"), e.get("placeholder"), e.get("text"))' "('ungrouped', 'ungrouped', 'Group name', '')"
hl_check "G14 its pencil opens the empty Group name field" $? "$(sb wa)"
sb wa --edit=team --edit-key=enter > /dev/null
hl_wait_for 10 is wa '("ungrouped" in [x["kind"] for x in r], sorted(x["label"] for x in r if x["kind"] == "window" and under(x["label"]) == "team"))' "(False, $lone)"
hl_check "G15 Return names every lone window as that group, and the Ungrouped header goes" $? "lone=$lone $(sb wa)"
hl_wait_for 10 lst_is '"team: wa" in T' True
hl_check "G16 each retitled <group>: <its title>" $? "$(lst 'T')"
grep -q 'pane sidebar ungrouped grouped windows=' "$APP_LOG"
hl_check "G16b logged" $?

hl_finish "$L"
