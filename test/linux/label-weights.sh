#!/usr/bin/env bash
# label-weights.sh - T3791 acceptance: the GTK chrome draws its titles at the
# Mac's semibold (600), not Adwaita's bold (700). The header bar's title, the
# Settings window's headings and the shortcut guide's badges are read through
# the debug-only `label-weights` seam (IpcHandlers.labelWeightsSeam), which
# reports the weight CSS computed for every label of a window.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\label-weights.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh).
#
# Positive control (B6-B7): a user's gtk-custom-css asking for 800 must move
# the title to 800 after +reload, so a seam that always answered 600 - or a
# rule that never applied - goes red.
#
# Output: one PASS/FAIL line per check, then 'LABEL WEIGHTS: ALL PASS' or
# 'LABEL WEIGHTS: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="LABEL WEIGHTS"

log=/tmp/label-weights-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "B1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "B2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
dev="$cfg_dir/config-debug.ghostty"
mkdir -p "$cfg_dir"
printf '# label weights\n' > "$dev"

# lw <python expr over labels> [seam args...]: one answer about the labels.
lw() {
    expr=$1; shift
    hl_ipc label-weights "$@" | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
labels = r.get("labels", [])
mapped = [l for l in labels if l["mapped"]]
title = [l for l in mapped if "title" in l["classes"] and l["parent"] == "windowtitle"]
print(eval(sys.argv[1]))' "$expr" 2>/dev/null
}

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false --title=Weights -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "B3 the app serves its socket" $?
pane=""; for _ in $(seq 1 50); do pane=$(hl_first_pane "$app"); [ -n "$pane" ] && break; sleep 0.2; done

# ---- the header bar's title ---------------------------------------------------
got=""; for _ in $(seq 1 50); do got=$(lw '[(l["text"], l["weight"]) for l in title]' --target="$pane"); [ "$got" != "[]" ] && [ -n "$got" ] && break; sleep 0.2; done
[ "$(lw 'len(title) >= 1 and all(l["weight"] == 600 for l in title)' --target="$pane")" = True ]
hl_check "B4 the header bar's title is semibold (600), not Adwaita's bold" $? "title=$got"
bold=$(lw '[(l["text"], l["weight"], l["classes"], l["parent"]) for l in mapped if l["weight"] >= 700]' --target="$pane")
[ "$bold" = "[]" ]
hl_check "B5 no label the window shows is bold (the Mac's chrome has none)" $? "bold=$bold"

# ---- positive control: a user's CSS still wins, and the seam sees it ----------
css="$cfg_dir/heavy.css"
printf 'windowtitle .title { font-weight: 800; }\n' > "$css"
printf 'gtk-custom-css = %s\n' "$css" >> "$dev"
cli +reload > /dev/null 2>&1
heavy() { [ "$(lw 'len(title) >= 1 and all(l["weight"] == 800 for l in title)' --target="$pane")" = True ]; }
hl_wait_for 10 heavy
hl_check "B6 control: gtk-custom-css asking for 800 moves the title to 800" $? "title=$(lw '[(l["text"], l["weight"]) for l in title]' --target="$pane")"
printf '# label weights\n' > "$dev"
cli +reload > /dev/null 2>&1
semi() { [ "$(lw 'len(title) >= 1 and all(l["weight"] == 600 for l in title)' --target="$pane")" = True ]; }
hl_wait_for 10 semi
hl_check "B7 control: with the custom CSS gone the title is back at 600" $?

# ---- the Settings window's headings -------------------------------------------
hl_ipc settings --op=action > /dev/null
opened() { [ "$(lw 'len(labels) > 0' --of=settings)" = True ]; }
hl_wait_for 10 opened
hl_check "B8 the Settings window opens" $?
h=$(lw '[(l["text"], l["weight"]) for l in labels if "heading" in l["classes"]]' --of=settings)
[ "$(lw 'any("heading" in l["classes"] for l in labels) and all(l["weight"] == 600 for l in labels if "heading" in l["classes"])' --of=settings)" = True ]
hl_check "B9 every .heading in the Settings window is semibold" $? "headings=$h"
hl_ipc settings --op=close > /dev/null

# ---- the shortcut guide's badges ----------------------------------------------
hl_ipc press-key --target="$pane" --key=ctrl+shift+/ > /dev/null
guide() { [ "$(lw 'len(labels) > 0' --of=guide)" = True ]; }
hl_wait_for 10 guide
hl_check "B10 the shortcut guide opens" $?
b=$(lw '[(l["text"], l["weight"]) for l in labels if "ghoztty-badge" in l["classes"]][:5]' --of=guide)
[ "$(lw 'any("ghoztty-badge" in l["classes"] for l in labels) and all(l["weight"] == 600 for l in labels if "ghoztty-badge" in l["classes"])' --of=guide)" = True ]
hl_check "B11 the guide's badges are semibold, as the Mac's Badge is" $? "badges=$b"

hl_finish "$L"
