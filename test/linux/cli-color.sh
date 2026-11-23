#!/usr/bin/env bash
# cli-color.sh - T3382 acceptance for pane tinting on the GTK debug app:
# `+new-window --color`, `--split-color` and `+split --color` (T67 on Linux:
# #rgb, #rrggbb or random), the tint a split inherits from its parent, and the
# contrast foreground that comes with a tint (the Mac applyColorScheme, win32
# Surface.applyBackgroundTint). Two observables per pane: `+list --json`'s
# additive `background_tint`, and the pane's own render read back through the
# debug-only capture-pane seam (T3359) - the field alone would not prove the
# terminal changed colour.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-color.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh).
#
# Output: one PASS/FAIL line per check, then 'CLI COLOR: ALL PASS' or
# 'CLI COLOR: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI COLOR"

log=/tmp/cli-color-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "K1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "K2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

# A known configured background and foreground, so "untinted" is checkable.
cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
printf 'background = #203040\nforeground = #e0e0e0\nbackground-opacity = 1\nwindow-padding-color = background\n' > "$cfg_dir/config.ghostty"

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "K3 the app serves its socket" $?
first=""; for _ in $(seq 1 50); do first=$(hl_first_pane "$app"); [ -n "$first" ] && break; sleep 0.2; done
[ -n "$first" ]
hl_check "K4 the app lists its first pane" $? "pane=$first"

# leaf <window-target> <pane-name|*> <field>: one field of that pane's +list
# leaf ('*' = the window's first pane), or nothing.
leaf() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
want_w, want_p, field = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if want_w != "" and (w.get("target") or "") != want_w: continue
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if want_p == "*" or l.get("name") == want_p:
                print(l.get(field, "")); sys.exit(0)
' "$1" "$2" "$3" 2>/dev/null
}
id_of() { leaf "$1" "$2" id; }
tint_of() { leaf "$1" "$2" background_tint; }

shot="$HL_RUNTIME/pane.png"
# fill <pane-id> <r> <g> <b>: the fraction of the pane's pixels within 8 of it.
fill() {
    hl_screenshot "$1" "$shot" > /dev/null || { echo 0; return; }
    hl_png_stats "$shot" "$2" "$3" "$4" | sed -n 's/.*match=\([0-9.]*\).*/\1/p'
}
# mostly <pane-id> <r> <g> <b>: over half the pane is that colour.
mostly() { awk -v m="$(fill "$@")" 'BEGIN{exit !(m > 0.5)}'; }

# ---- the control: an untinted pane shows the config's background -----------
hl_wait_for 15 mostly "$first" 32 48 64
hl_check "K5 an untinted pane shows the configured background (#203040)" $? "fill=$(fill "$first" 32 48 64)"
[ -z "$(leaf "" '*' background_tint)" ]
hl_check "K6 an untinted pane lists no background_tint" $? "tint='$(leaf "" '*' background_tint)'"

# ---- +new-window --color ------------------------------------------------------
o=$(cli +new-window --target=tinted --color='#a05010' 2>&1); rc=$?
hl_check "K7 +new-window --color=#a05010 succeeds" $rc "$o"
tp=""; for _ in $(seq 1 50); do tp=$(id_of tinted '*'); [ -n "$tp" ] && break; sleep 0.2; done
[ "$(tint_of tinted '*')" = "#a05010" ]
hl_check "K8 its pane lists background_tint #a05010" $? "tint='$(tint_of tinted '*')'"
hl_wait_for 15 mostly "$tp" 160 80 16
hl_check "K9 its pane renders the tint (#a05010)" $? "fill=$(fill "$tp" 160 80 16) cfg=$(fill "$tp" 32 48 64)"
mostly "$first" 32 48 64
hl_check "K10 the first window's pane is untouched (#203040)" $? "fill=$(fill "$first" 32 48 64)"

# ---- a split inherits its parent's tint -------------------------------------
o=$(cli +split --target=tinted --name=heir 2>&1); rc=$?
hl_check "K11 +split with no --color succeeds" $rc "$o"
hp=""; for _ in $(seq 1 50); do hp=$(id_of tinted heir); [ -n "$hp" ] && break; sleep 0.2; done
[ "$(tint_of tinted heir)" = "#a05010" ]
hl_check "K12 the split inherits its parent's tint (lists #a05010)" $? "tint='$(tint_of tinted heir)'"
hl_wait_for 15 mostly "$hp" 160 80 16
hl_check "K13 the inheriting split renders the parent's tint" $? "fill=$(fill "$hp" 160 80 16)"

# ---- +split --color overrides the inherited tint ----------------------------
o=$(cli +split --target=tinted --name=green --color='#105020' 2>&1); rc=$?
hl_check "K14 +split --color=#105020 succeeds" $rc "$o"
gp=""; for _ in $(seq 1 50); do gp=$(id_of tinted green); [ -n "$gp" ] && break; sleep 0.2; done
[ "$(tint_of tinted green)" = "#105020" ]
hl_check "K15 the split lists its own tint #105020, not the inherited one" $? "tint='$(tint_of tinted green)'"
hl_wait_for 15 mostly "$gp" 16 80 32
hl_check "K16 the split renders #105020" $? "fill=$(fill "$gp" 16 80 32) inherited=$(fill "$gp" 160 80 16)"

# ---- +new-window --color + --split + --split-color ---------------------------
o=$(cli +new-window --target=both --color='#3366cc' --split=right --split-color='#cc6633' --name=right 2>&1); rc=$?
hl_check "K17 +new-window --color --split=right --split-color succeeds" $rc "$o"
rp=""; for _ in $(seq 1 50); do rp=$(id_of both right); [ -n "$rp" ] && break; sleep 0.2; done
bp=$(id_of both '*')
[ "$(tint_of both '*')" = "#3366cc" ] && [ "$(tint_of both right)" = "#cc6633" ]
hl_check "K18 first pane lists #3366cc, the inline split #cc6633" $? "first='$(tint_of both '*')' split='$(tint_of both right)'"
hl_wait_for 15 mostly "$bp" 51 102 204
r1=$?
hl_wait_for 15 mostly "$rp" 204 102 51
r2=$?
[ $r1 = 0 ] && [ $r2 = 0 ]
hl_check "K19 both panes render their own tint" $? "first=$(fill "$bp" 51 102 204) split=$(fill "$rp" 204 102 51)"

# ---- the #rgb short form and random ------------------------------------------
o=$(cli +new-window --target=short --color='#a5c' 2>&1); rc=$?
for _ in $(seq 1 50); do [ -n "$(id_of short '*')" ] && break; sleep 0.2; done
[ $rc = 0 ] && [ "$(tint_of short '*')" = "#aa55cc" ]
hl_check "K20 --color=#a5c is the #aa55cc short form" $? "rc=$rc $o tint='$(tint_of short '*')'"

o=$(cli +new-window --target=rnd --color=random 2>&1); rc=$?
for _ in $(seq 1 50); do [ -n "$(id_of rnd '*')" ] && break; sleep 0.2; done
rt=$(tint_of rnd '*')
printf '%s' "$rt" | grep -Eq '^#[0-9a-f]{6}$'
hl_check "K21 --color=random lists a concrete #rrggbb tint" $? "rc=$rc $o tint='$rt'"
rr=$((16#${rt:1:2})); rg=$((16#${rt:3:2})); rb=$((16#${rt:5:2}))
[ $rr -lt 80 ] && [ $rg -lt 80 ] && [ $rb -lt 80 ]
r1=$?
hl_wait_for 15 mostly "$(id_of rnd '*')" $rr $rg $rb
r2=$?
[ $r1 = 0 ] && [ $r2 = 0 ]
hl_check "K22 the random tint is dark and is what the pane renders" $? "tint=$rt fill=$(fill "$(id_of rnd '*')" $rr $rg $rb)"

# ---- the contrast foreground comes with the tint ------------------------------
# Reverse video paints each cell in the FOREGROUND colour, so a screenful of
# reversed spaces shows the pane's foreground. On a light tint the scheme's
# foreground is black; the untinted config foreground is #e0e0e0.
paint='printf "\033[7m"; i=0; while [ $i -lt 600 ]; do printf "          "; i=$((i+1)); done; exec sleep 600'
o=$(cli +new-window --target=light --color='#f0f0f0' -e /bin/sh -c "$paint" 2>&1); rc=$?
o2=$(cli +new-window --target=plain -e /bin/sh -c "$paint" 2>&1); rc2=$?
for _ in $(seq 1 50); do [ -n "$(id_of light '*')" ] && [ -n "$(id_of plain '*')" ] && break; sleep 0.2; done
lp=$(id_of light '*'); pp=$(id_of plain '*')
some() { awk -v m="$(fill "$@")" 'BEGIN{exit !(m > 0.3)}'; }
hl_wait_for 15 some "$lp" 0 0 0
r1=$?
hl_wait_for 15 some "$pp" 224 224 224
r2=$?
[ $rc = 0 ] && [ $rc2 = 0 ] && [ $r1 = 0 ] && [ $r2 = 0 ]
hl_check "K23 a light tint brings a black foreground (the untinted pane keeps #e0e0e0)" $? "rc=$rc/$rc2 light-black=$(fill "$lp" 0 0 0) plain-fg=$(fill "$pp" 224 224 224)"
[ "$(awk -v m="$(fill "$pp" 0 0 0)" 'BEGIN{print (m < 0.05)}')" = 1 ]
hl_check "K24 negative control: the untinted reversed pane has no black foreground" $? "plain-black=$(fill "$pp" 0 0 0)"

# ---- a bad value is refused by the CLI, not applied ----------------------------
o=$(cli +new-window --target=bad --color=notacolor 2>&1); rc=$?
[ $rc != 0 ] || [ -z "$(tint_of bad '*')" ]
hl_check "K25 --color=notacolor tints nothing" $? "rc=$rc $o tint='$(tint_of bad '*')'"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "K26 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- app log (tail) ----"
    tail -40 "$APP_LOG" 2>/dev/null
fi

hl_finish "$L"
