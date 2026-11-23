#!/usr/bin/env bash
# session-restore-viewers.sh - T3420 (Linux L9k) acceptance: viewer panes come
# back with the session. A viewer has no agent session to re-attach, so
# re-opening it IS its restore: it re-opens where it IS (a pane that navigated
# away from its file stays away), keeps where it was OPENED as its Home, keeps
# its pane id and name, and keeps the directory it was opened from - so a
# diff pane re-runs in that repository. A picture comes back at best fit, and
# a file deleted while the app was down shows the viewer's own error card.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\session-restore-viewers.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), whose private
# XDG_CONFIG_HOME holds the manifest. Pages are read back through the debug
# build's GHOZTTY_TEST_VIEWER_DUMP_ALL seam (every viewer's first render) and
# the first viewer's GHOZTTY_TEST_VIEWER_STEPS (src/apprt/gtk/Viewer.zig).
#
# Output: one PASS/FAIL line per check, then 'SESSION RESTORE VIEWERS: ALL PASS'
# or 'SESSION RESTORE VIEWERS: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="SESSION RESTORE VIEWERS"

log=/tmp/session-restore-viewers-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "V1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
app=$(hl_ghoztty) || hl_finish "$L"
manifest="$XDG_CONFIG_HOME/ghoztty/session-layout-debug.json"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
serving() { cli +list > /dev/null 2>&1; }
export SHELL=/bin/sh

# ---- fixtures ---------------------------------------------------------------
fx="$HL_RUNTIME/fx"
mkdir -p "$fx/repo"
printf '# Home Doc\n\ntext\n' > "$fx/doc.md"
printf '# Away Doc\n\ntext\n' > "$fx/other.md"
printf '# Gone Doc\n' > "$fx/gone.md"
python3 - "$fx/pic.png" <<'PY'
import struct, sys, zlib
w, h = 3000, 2000
raw = b"".join(b"\x00" + bytes((40, 90, 200)) * w for _ in range(h))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
PY
(
    cd "$fx/repo" && env -u GIT_DIR -u GIT_WORK_TREE git init -q . &&
    printf 'one\n' > tracked.txt &&
    env -u GIT_DIR -u GIT_WORK_TREE git -c user.email=t@t -c user.name=t add tracked.txt &&
    env -u GIT_DIR -u GIT_WORK_TREE git -c user.email=t@t -c user.name=t commit -qm init &&
    printf 'one\ntwo\n' > tracked.txt
) > /dev/null 2>&1
repo="$fx/repo"

# leaves: one line per +list leaf, 'name|type|id|url'.
leaves() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            print("%s|%s|%s|%s" % (l.get("name") or "", l.get("type"), l.get("id") or "", l.get("url") or ""))
' 2>/dev/null
}
leaf() { leaves | awk -F'|' -v n="$1" '$1 == n'; }
field() { leaf "$1" | cut -d'|' -f"$2"; }
viewer_count() { leaves | awk -F'|' '$2 == "viewer"' | wc -l; }
# mleaf <name> <key>: a manifest leaf's field, by its recorded name.
mleaf() {
    python3 -c '
import json, sys
try: m = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for w in m.get("windows", []):
    for t in w["tabs"]:
        for n in t["nodes"]:
            l = n.get("leaf")
            if l and l.get("ipc_name") == sys.argv[2]:
                print(l.get(sys.argv[3]) or ""); sys.exit(0)
' "$manifest" "$1" "$2" 2>/dev/null
}

# ---- 1. a running app records four viewers ---------------------------------
# The first viewer to render runs these steps: it navigates AWAY from the
# file it was opened on, so where it IS and its Home differ.
steps="$HL_RUNTIME/steps"; out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
type $fx/other.md
activate
wait
mark away
EOF
dump="$HL_RUNTIME/dump"
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_STEPS="$steps" GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
hl_launch APP "$app" --gtk-single-instance=false
unset GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT
hl_wait_for 30 serving
hl_check "V2 the app serves its socket" $?

o=$(cli +new-window --target=wv --name=doc --view="$fx/doc.md" --working-directory="$fx" 2>&1)
hl_check "V3 +new-window --view=doc.md opens a viewer window" $? "$o"
hl_wait_for 60 grep -q '^mark away' "$out"
[ "$(field doc 4)" = "$fx/other.md" ]
hl_check "V4 the doc pane navigated away from its file (now on other.md)" $? "doc: $(leaf doc) steps: $(tr '\n' ' ' < "$out" 2>/dev/null)"

o1=$(cli +split --pane=doc --name=img --direction=right --view="$fx/pic.png" 2>&1); r1=$?
o2=$(cli +split --pane=img --name=diff --direction=down --view=git-status: --working-directory="$repo" 2>&1); r2=$?
o3=$(cli +split --pane=doc --name=gone --direction=down --view="$fx/gone.md" 2>&1); r3=$?
[ $r1 = 0 ] && [ $r2 = 0 ] && [ $r3 = 0 ] && [ "$(viewer_count)" = 4 ]
hl_check "V5 three more viewer splits (picture, git-status diff, a doc to delete)" $? "$o1 | $o2 | $o3 | $(leaves | tr '\n' ' ')"
id_doc=$(field doc 3); id_img=$(field img 3); id_diff=$(field diff 3); id_gone=$(field gone 3)

recorded() {
    [ "$(mleaf doc viewer_location)" = "$fx/other.md" ] && [ "$(mleaf gone kind)" = viewer ] &&
        [ "$(mleaf diff viewer_origin_directory)" = "$repo" ]
}
hl_wait_for 10 recorded
hl_check "V6 the manifest records each viewer's location" $? "doc=$(mleaf doc viewer_location) gone=$(mleaf gone kind) diff-origin=$(mleaf diff viewer_origin_directory)"
[ "$(mleaf doc viewer_home_location)" = "$fx/doc.md" ] && [ "$(mleaf doc viewer_origin_directory)" = "$fx" ] &&
    [ "$(mleaf img viewer_home_location)" = "$fx/pic.png" ]
hl_check "V7 ...its Home (where it was opened) and the directory it was opened from" $? "doc home=$(mleaf doc viewer_home_location) origin=$(mleaf doc viewer_origin_directory) img home=$(mleaf img viewer_home_location)"
[ "$(mleaf doc pane_id)" = "$id_doc" ] && [ "$(mleaf diff pane_id)" = "$id_diff" ]
hl_check "V8 ...and its pane id" $? "doc=$(mleaf doc pane_id)/$id_doc diff=$(mleaf diff pane_id)/$id_diff"

# ---- 2. crash, delete a file, relaunch ---------------------------------------
kill -KILL "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
rm -f "$fx/gone.md"
all="$HL_RUNTIME/dump-all"; : > "$all"
export GHOZTTY_TEST_VIEWER_DUMP_ALL="$all"
export GHOZTTY_TEST_VIEWER_PROBE="(function(){var h=document.querySelector('#content h1');if(h)return 'H1 '+h.textContent;return 'BODY '+(document.body?document.body.innerText.replace(/\\s+/g,' ').slice(0,160):'NOBODY')})()"
hl_launch APP2 "$app" --gtk-single-instance=false
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_DUMP_ALL GHOZTTY_TEST_VIEWER_PROBE
hl_wait_for 30 serving
four() { [ "$(viewer_count)" = 4 ]; }
hl_wait_for 20 four
hl_check "V9 the relaunch brings back all four viewer panes" $? "$(leaves | tr '\n' ' ')"
[ "$(field doc 3)" = "$id_doc" ] && [ "$(field img 3)" = "$id_img" ] && [ "$(field diff 3)" = "$id_diff" ] && [ "$(field gone 3)" = "$id_gone" ]
hl_check "V10 ...each under its own name and pane id" $? "$(leaves | tr '\n' ' ') want $id_doc $id_img $id_diff $id_gone"
[ "$(field doc 4)" = "$fx/other.md" ]
hl_check "V11 the doc pane re-opens where it WAS (other.md), not at its Home" $? "doc: $(leaf doc)"
hl_wait_for 40 grep -q "^$fx/other.md	" "$all"
grep -q "^$fx/other.md	OK H1 Away Doc$" "$all"
hl_check "V12 ...and renders that page" $? "$(tr '\n' '~' < "$all")"
hl_wait_for 40 grep -q "^$fx/gone.md	" "$all"
grep "^$fx/gone.md	" "$all" | grep -q 'Cannot read file'
hl_check "V13 the file deleted while the app was down shows the error card in the page" $? "$(grep "gone.md" "$all")"
hl_wait_for 40 grep -q "viewer diff spec=git-status: repo=$repo " "$APP2_LOG"
grep -q "viewer diff spec=git-status: repo=$repo files=1 " "$APP2_LOG"
hl_check "V14 the diff pane re-runs in the directory it was opened from (1 changed file)" $? "$(grep -m2 'viewer diff spec' "$APP2_LOG")"
hl_wait_for 40 grep -q 'viewer image rev=1 .*natural=3000x2000' "$APP2_LOG"
img_line=$(grep 'viewer image rev=1 .*natural=3000x2000' "$APP2_LOG" | tail -1)
case "$img_line" in *"fitting=true"*) fit_ok=0 ;; *) fit_ok=1 ;; esac
zoom=$(echo "$img_line" | sed -n 's/.* zoom=\([0-9.]*\).*/\1/p')
[ $fit_ok = 0 ] && python3 -c "import sys; sys.exit(0 if 0 < float(sys.argv[1]) < 1 else 1)" "${zoom:-0}"
hl_check "V15 the picture comes back at best fit (fitting, zoom under 100%)" $? "$img_line"

# ---- 3. what the restored panes record: Home and origin survived ------------
kill -TERM "$APP2" 2>/dev/null
hl_wait_for 15 sh -c "! kill -0 $APP2 2>/dev/null"
hl_check "V16 SIGTERM quits the relaunched app" $?
[ "$(mleaf doc viewer_home_location)" = "$fx/doc.md" ] && [ "$(mleaf doc viewer_location)" = "$fx/other.md" ] &&
    [ "$(mleaf doc viewer_origin_directory)" = "$fx" ] && [ "$(mleaf diff viewer_origin_directory)" = "$repo" ]
hl_check "V17 the restored panes' own capture still holds each Home and origin directory" $? "doc home=$(mleaf doc viewer_home_location) at=$(mleaf doc viewer_location) origin=$(mleaf doc viewer_origin_directory) diff origin=$(mleaf diff viewer_origin_directory)"
! grep -q 'panic\|reached unreachable' "$APP2_LOG"
hl_check "V18 no panic in the relaunched app" $? "$(grep -m2 'panic\|unreachable' "$APP2_LOG")"

hl_finish "$L"
