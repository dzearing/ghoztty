#!/usr/bin/env bash
# cli-sidebar.sh - L10b (T3557) acceptance for the pane sidebar on the GTK
# debug app (docs/reference/pane-sidebar.md): a per-window list of the active
# tab's panes, named by banner title else title with the directory under it,
# the focused pane selected; the rail and the panel switched by ONE button; a
# narrow window held in the rail; Ctrl+Shift+S (toggle_pane_sidebar) hiding
# and showing it; the flags shared by every window, kept across a relaunch,
# and forced by macos-pane-sidebar without being written over. Run it ONLY
# through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-sidebar.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop. The sidebar is read back through the
# debug build's `pane-sidebar` IPC seam (IpcHandlers.zig), which also clicks
# its button or a row - the harness has no pointer.
#
# NEGATIVE=1 makes the toggle chord the wrong one, which must FAIL S12
# (the harness can see a sidebar that does not hide).
#
# Output: one PASS/FAIL line per check, then 'CLI SIDEBAR: ALL PASS' or
# 'CLI SIDEBAR: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI SIDEBAR"

log=/tmp/cli-sidebar-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "F1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
prefs="$XDG_CONFIG_HOME/ghoztty/pane-sidebar-debug"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/sidebar-fixture"
mkdir -p "$fixture/proj"
export SHELL=/bin/sh
export HOME="$fixture"

launch() {
    local var=$1; shift
    rm -f "$sock"
    hl_launch "$var" "$app" --gtk-single-instance=false --session-persistence=false \
        --working-directory="$fixture/proj" "$@" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
    hl_wait_for 30 test -S "$sock"
}
stop() { kill -TERM "$1" 2>/dev/null; hl_wait_for 10 sh -c "! kill -0 $1 2>/dev/null"; }

# sb <target> [click]: the seam's report for that target's window (after a
# click on 'toggle' or a pane id), one JSON object.
sb() {
    if [ $# -gt 1 ]; then hl_ipc pane-sidebar "--target=$1" "--click=$2" 2>/dev/null
    else hl_ipc pane-sidebar "--target=$1" 2>/dev/null; fi
}
# field <target> <python expr over s (the sidebar) and r (its rows)>
field() {
    sb "$1" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
s = d.get("sidebar") or {}
# The pane rows: the list also holds this window header and the rail +
# (T3695, their own suite is cli-sidebar-header.sh).
r = [x for x in (s.get("rows") or []) if x["kind"] in ("terminal", "viewer")]
print(eval(sys.argv[1]))
' "$2" 2>/dev/null
}
is() { [ "$(field "$1" "$2")" = "$3" ]; }
panes() { # the active tab's pane ids of the window holding <target>, in tree order
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
want = sys.argv[1]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    tab = next((t for t in w["tabs"] if t.get("selected")), w["tabs"][0])
    ids = [l["id"] for l in leaves(tab["splits"])]
    if want in ids or (w.get("target") or "") == want:
        print(" ".join(ids))
' "$1" 2>/dev/null
}
focused() { # the focused pane id in the window holding <target>
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
want = sys.argv[1]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    tab = next((t for t in w["tabs"] if t.get("selected")), w["tabs"][0])
    ls = list(leaves(tab["splits"]))
    if want in [l["id"] for l in ls] or (w.get("target") or "") == want:
        print(next((l["id"] for l in ls if l.get("focused")), ""))
' "$1" 2>/dev/null
}

# ---- 1. one window: the rail, its rows ------------------------------------
launch APP
f3=$?
hl_check "F3 the app serves its socket" $f3
[ $f3 = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }
cli +new-window --target=sa > /dev/null 2>&1
hl_wait_for 15 is sa 's["mode"]' mini
hl_check "S1 with no saved flags the sidebar starts as the rail, shown" $? "$(sb sa)"
# A first launch lists every window (the Mac's default scope, T3558; its own
# suite is cli-sidebar-all.sh). This suite is the per-window list, so it
# switches the scope to this window once; the choice is kept from here on.
is sa 's["all_windows"]' True
hl_check "S0 a first launch starts in the all-windows scope" $? "$(sb sa)"
sb sa scope > /dev/null
hl_wait_for 10 is sa 's["all_windows"]' False
hl_check "S0b the scope button switches it to this window's panes" $? "$(sb sa)"
a=$(panes sa)
hl_wait_for 10 is sa 'len(r)' 1
hl_check "S2 the rail has one tile for the window's one pane" $? "$(sb sa)"
is sa '(r[0]["pane"], r[0]["selected"], r[0]["label_shown"], r[0]["kind"])' "('$a', True, False, 'terminal')"
hl_check "S3 the tile is that pane, selected, with no text on screen" $? "$(sb sa)"
# osc <pane> <payload>: the pane's shell prints ESC ] payload BEL. Bash's
# double quotes halve the backslashes, then +send-keys turns `\\` into `\`
# (cli-banner.sh's helper). /bin/sh reports no directory by itself, so the
# script sends the OSC 7 a shell integration would.
osc() { cli +send-keys --target="$1" "printf '\\\\033]$2\\\\007'" Enter > /dev/null 2>&1; }
osc "$a" "7;file://localhost$fixture/proj"
# The core titles a pane by its directory until a program sets a title, so
# the tile's name is that path, shown once (no subtitle repeating it).
hl_wait_for 10 is sa '(r[0]["label"].endswith("/proj"), r[0]["subtitle"], r[0]["tooltip"] == r[0]["label"])' "(True, None, True)"
hl_check "S4 the tile names the pane in a tooltip; titled by its directory, the path shows once" $? "$(sb sa)"

# ---- 2. rows follow the tree, a banner and a title -------------------------
cli +split --target=sa --name=b > /dev/null 2>&1
hl_wait_for 10 is sa 'len(r)' 2
hl_check "S5 a split adds a row, after its parent (tree order)" $? "$(sb sa)"
ids=$(panes sa); b=${ids#* }
is sa '[x["pane"] for x in r]' "['$a', '$b']"
hl_check "S6 the rows are the panes in tree order" $? "rows=$(field sa '[x["pane"] for x in r]') panes=$ids"
is sa '[x["selected"] for x in r]' "[True, False]"
hl_check "S7 the split opened without --focus, so the first row stays selected" $? "$(sb sa)"

cli +set-banner --target=b '## Build box
| step | state |
|---|---|
| a | done |' > /dev/null 2>&1
hl_wait_for 10 is sa 'r[1]["label"]' 'Build box'
hl_check "S8 a banner's heading names its pane's row" $? "$(sb sa)"
osc "$b" "7;file://localhost$fixture/proj"
hl_wait_for 10 is sa 'r[1]["subtitle"]' '~/proj'
hl_check "S9 under it, the pane's directory with home as ~" $? "$(sb sa)"
osc "$a" "2;hello-title"
hl_wait_for 10 is sa 'r[0]["label"]' 'hello-title'
hl_check "S10 a title the program sets renames its row" $? "$(sb sa)"

# ---- 3. the one button: rail <-> panel, persisted --------------------------
sb sa toggle > /dev/null
hl_wait_for 10 is sa '(s["mode"], s["expanded"], all(x["label_shown"] for x in r), all(x["tooltip"] is None for x in r))' "('expanded', True, True, True)"
hl_check "S11 the button expands the rail into the panel: text on screen, no tooltips" $? "$(sb sa)"
hl_wait_for 5 grep -q '^1 0 ' "$prefs"
hl_check "S11b the user's expand is written to the flags file" $? "$(cat "$prefs" 2>/dev/null)"
w_panel=$(field sa 's["width"]'); w_rail=52
[ "${w_panel:-0}" -gt "$w_rail" ] 2>/dev/null
hl_check "S11c the panel is wider than the rail" $? "panel=$w_panel"

# ---- 4. Ctrl+Shift+S hides and shows it -----------------------------------
chord=ctrl+shift+s
[ "${NEGATIVE:-0}" = 1 ] && chord=ctrl+shift+j
hl_ipc press-key "--target=$a" "--key=$chord" > /dev/null 2>&1
hl_wait_for 10 is sa '(s["mode"], s["visible"], len(r))' "('hidden', False, 0)"
hl_check "S12 Ctrl+Shift+S hides the sidebar" $? "$(sb sa)"
hl_ipc press-key "--target=$a" "--key=$chord" > /dev/null 2>&1
hl_wait_for 10 is sa '(s["mode"], s["visible"], len(r))' "('expanded', True, 2)"
hl_check "S13 pressed again it comes back as it was (the panel)" $? "$(sb sa)"

# ---- 5. a row's click focuses its pane ------------------------------------
sb sa "$b" > /dev/null
focused_is() { [ "$(focused "$1")" = "$2" ]; }
hl_wait_for 10 focused_is sa "$b"
hl_check "S14 clicking a row focuses that pane" $? "focused=$(focused sa) want=$b"
hl_wait_for 10 is sa '[x["selected"] for x in r]' "[False, True]"
hl_check "S15 and its row is the selected one" $? "$(sb sa)"

# ---- 6. one state for every window ----------------------------------------
cli +new-window --target=sb > /dev/null 2>&1
hl_wait_for 15 is sb 'len(r)' 1
hl_check "S16 a second window has its own list (its one pane)" $? "$(sb sb)"
is sb 's["mode"]' expanded
hl_check "S17 and the same shared mode (the panel)" $? "$(sb sb)"
sb sb toggle > /dev/null
hl_wait_for 10 is sa 's["mode"]' mini
hl_check "S18 collapsing in the second window collapses the first" $? "sa=$(sb sa)"

# ---- 7. a relaunch keeps the user's choice; a forced start does not write --
stop "$APP"
launch APP2
cli +new-window --target=sc > /dev/null 2>&1
hl_wait_for 15 is sc 's["mode"]' mini
hl_check "S19 a relaunch starts as the user left it (the rail)" $? "$(sb sc) file=$(cat "$prefs" 2>/dev/null)"
stop "$APP2"
launch APP3 --macos-pane-sidebar=expanded
cli +new-window --target=sd > /dev/null 2>&1
hl_wait_for 15 is sd 's["mode"]' expanded
hl_check "S20 macos-pane-sidebar=expanded starts every window as the panel" $? "$(sb sd)"
grep -q '^0 0 ' "$prefs"
hl_check "S21 the forced start is not written over the user's own flags" $? "$(cat "$prefs" 2>/dev/null)"
grep -q 'pane sidebar start=expanded moved=true' "$APP3_LOG"
hl_check "S22 the forced start is logged with its cause" $?
stop "$APP3"

# ---- 8. a narrow window holds the rail ------------------------------------
launch APP4 --macos-pane-sidebar=expanded --window-width=40 --window-height=20
cli +new-window --target=se > /dev/null 2>&1
hl_wait_for 15 is se '(s["mode"], s["expanded"], s["can_expand"])' "('mini', True, False)"
hl_check "S23 a window narrower than 720 shows the rail, expanded or not, its button off" $? "$(sb se)"
sb se toggle > /dev/null
is se 's["expanded"]' True
hl_check "S24 the button does nothing there (the flag is untouched)" $? "$(sb se)"
stop "$APP4"

hl_finish "$L"
